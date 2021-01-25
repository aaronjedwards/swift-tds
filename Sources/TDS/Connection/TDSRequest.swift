import NIO
import NIOSSL
import NIOTLS
import Logging

extension TDSConnection: TDSClient {
    public func send(_ request: TDSRequest, logger: Logger) -> EventLoopFuture<Void> {
        request.log(to: self.logger)
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        let request = TDSRequestContext(delegate: request, promise: promise)
        self.channel.writeAndFlush(request).cascadeFailure(to: promise)
        return promise.futureResult
    }
}

public protocol TDSRequest {
    // nil value ends the request
    func respond(to packet: TDSPacket, allocator: ByteBufferAllocator) throws -> [TDSPacket]?
    func start(allocator: ByteBufferAllocator) throws -> [TDSPacket]
    func log(to logger: Logger)
}

final class TDSRequestContext {
    let delegate: TDSRequest
    let promise: EventLoopPromise<Void>
    var lastError: Error?
    
    init(delegate: TDSRequest, promise: EventLoopPromise<Void>) {
        self.delegate = delegate
        self.promise = promise
    }
}

final class TDSRequestHandler: ChannelDuplexHandler {
    typealias InboundIn = TDSPacket
    typealias OutboundIn = TDSRequestContext
    typealias OutboundOut = TDSPacket
    
    /// `TDSMessage` handlers
    var firstDecoder: ByteToMessageHandler<TDSPacketDecoder>
    var firstEncoder: MessageToByteHandler<TDSPacketEncoder>
    var tlsConfiguration: TLSConfiguration?
    var serverHostname: String?
    
    var sslClientHandler: NIOSSLClientHandler?
    
    var pipelineCoordinator: PipelineOrganizationHandler!
    
    enum State: Int {
        case start
        case sentInitialTDSPreLogin
        case receivedTDSPreLoginResponse
        case sslHandshakeStarted
        case sslHandshakeComplete
        case sentTDSLogin
        case loggedIn
    }
    
    private var state = State.start
    
    private var queue: [TDSRequestContext]
    let logger: Logger
    
    public init(
        logger: Logger,
        _ firstDecoder: ByteToMessageHandler<TDSPacketDecoder>,
        _ firstEncoder: MessageToByteHandler<TDSPacketEncoder>,
        _ tlsConfiguration: TLSConfiguration? = nil,
        _ serverHostname: String? = nil
    ) {
        self.logger = logger
        self.queue = []
        self.firstDecoder = firstDecoder
        self.firstEncoder = firstEncoder
        self.tlsConfiguration = tlsConfiguration
        self.serverHostname = serverHostname
    }
    
    private func _channelRead(context: ChannelHandlerContext, data: NIOAny) throws {
        let packet = self.unwrapInboundIn(data)
        guard self.queue.count > 0 else {
            // discard packet
            return
        }
        
        let request = self.queue[0]
        
        switch (state, packet.headerType) {
        case (.sentInitialTDSPreLogin, .preloginResponse):
            state = .receivedTDSPreLoginResponse
        case (_, .loginResponse):
            state = .loggedIn
        default:
            break
        }
        
        if let responses = try request.delegate.respond(to: packet, allocator: context.channel.allocator) {
            guard let first = responses.first else {
                return
            }
            switch (state, first.headerType) {
            case (.receivedTDSPreLoginResponse, .sslKickoff):
                try sslKickoff(context: context)
            default:
                for response in responses {
                    context.write(self.wrapOutboundOut(response), promise: nil)
                }
                context.flush()
            }
        } else {
            cleanupRequest(request)
        }
    }
    
    private func sslKickoff(context: ChannelHandlerContext) throws {
        guard let tlsConfig = tlsConfiguration else {
            throw TDSError.protocolError("Encryption was requested but a TLS Configuration was not provided.")
        }
        
        let sslContext = try! NIOSSLContext(configuration: tlsConfig)
        let sslHandler = try! NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
        self.sslClientHandler = sslHandler
        
        let coordinator = PipelineOrganizationHandler(logger: logger, firstDecoder, firstEncoder, sslHandler)
        self.pipelineCoordinator = coordinator
        
        context.channel.pipeline.addHandler(coordinator, position: .before(self)).whenComplete { _ in
            context.channel.pipeline.addHandler(sslHandler, position: .after(coordinator)).whenComplete { _ in
                self.state = .sslHandshakeStarted
            }
        }
    }
    
    private func cleanupRequest(_ request: TDSRequestContext) {
        self.queue.removeFirst()
        if let error = request.lastError {
            request.promise.fail(error)
        } else {
            request.promise.succeed(())
        }
    }
    
    private func _write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) throws {
        let request = self.unwrapOutboundIn(data)
        self.queue.append(request)
        
        var packets = try request.delegate.start(allocator: context.channel.allocator)
        guard let first = packets.first else {
            return
        }
        
        switch (state, first.headerType) {
        case (.start, .prelogin):
            state = .sentInitialTDSPreLogin
        case (_, .tds7Login):
            if state.rawValue >= State.receivedTDSPreLoginResponse.rawValue  {
                state = .sentTDSLogin
            }
        default:
            break
        }
        
        if let last = packets.popLast() {
            for item in packets {
                context.write(self.wrapOutboundOut(item), promise: nil)
            }
            context.write(self.wrapOutboundOut(last), promise: promise)
        } else {
            promise?.succeed(())
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            try self._channelRead(context: context, data: data)
        } catch {
            self.errorCaught(context: context, error: error)
        }
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        do {
            try self._write(context: context, data: data, promise: promise)
        } catch {
            self.errorCaught(context: context, error: error)
        }
    }
    
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        for current in self.queue {
            current.promise.fail(TDSError.connectionClosed)
        }
        self.queue = []
        context.close(mode: mode, promise: promise)
    }
    
    private func _userInboundEventTriggered(context: ChannelHandlerContext, event: Any) throws {
        if let sslHandler = sslClientHandler, let sslHandshakeComplete = event as? TLSUserEvent, case .handshakeCompleted = sslHandshakeComplete {
            // SSL Handshake complete
            // Remove pipeline coordinator and rearrange message encoder/decoder
            
            let future = EventLoopFuture.andAllSucceed([
                context.channel.pipeline.removeHandler(self.pipelineCoordinator),
                context.channel.pipeline.removeHandler(self.firstDecoder),
                context.channel.pipeline.removeHandler(self.firstEncoder),
                context.channel.pipeline.addHandler(ByteToMessageHandler(TDSPacketDecoder(logger: logger)), position: .after(sslHandler)),
                context.channel.pipeline.addHandler(MessageToByteHandler(TDSPacketEncoder(logger: logger)), position: .after(sslHandler))
            ], on: context.eventLoop)
            
            future.whenSuccess {_ in
                self.logger.debug("Done w/ SSL Handshake and pipeline organization")
                if let request = self.queue.first {
                    self.cleanupRequest(request)
                }
                self.state = .sslHandshakeComplete
            }
            
            future.whenFailure { error in
                self.errorCaught(context: context, error: error)
            }
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        do {
            try self._userInboundEventTriggered(context: context, event: event)
        } catch {
            self.errorCaught(context: context, error: error)
        }
    }
    
    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        
    }
}
