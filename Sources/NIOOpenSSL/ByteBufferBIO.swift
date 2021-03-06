//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import CNIOOpenSSL


/// The OpenSSL entry point to write to the `ByteBufferBIO`. This thunk unwraps the user data
/// and then passes the call on to the specific BIO reference.
///
/// This specific type signature is annoying (I'd rather have UnsafeRawPointer, and rather than a separate
/// len I'd like a buffer pointer), but this interface is required because this is passed to an OpenSSL
/// function pointer and so needs to be @convention(c).
internal func openSSLBIOWriteFunc(bio: UnsafeMutablePointer<BIO>?, buf: UnsafePointer<CChar>?, len: CInt) -> CInt {
    guard let concreteBIO = bio, let concreteBuf = buf else {
        preconditionFailure("Invalid pointers in openSSLBIOWriteFunc: bio: \(String(describing: bio)) buf: \(String(describing: buf))")
    }

    // This unwrap may fail if the user has dropped the ref to the ByteBufferBIO but still has
    // a ref to the other pointer. Sigh heavily and just fail.
    guard let userPtr = CNIOOpenSSL_BIO_get_data(concreteBIO) else {
        return -1
    }

    // Begin by clearing retry flags. We do this at all OpenSSL entry points.
    CNIOOpenSSL_BIO_clear_retry_flags(concreteBIO)

    // In the event a write of 0 bytes has been asked for, just return early, don't bother with the other work.
    guard len > 0 else {
        return 0
    }

    let swiftBIO: ByteBufferBIO = Unmanaged.fromOpaque(userPtr).takeUnretainedValue()
    let bufferPtr = UnsafeRawBufferPointer(start: concreteBuf, count: Int(len))
    return swiftBIO.sslWrite(buffer: bufferPtr)
}

/// The OpenSSL entry point to read from the `ByteBufferBIO`. This thunk unwraps the user data
/// and then passes the call on to the specific BIO reference.
///
/// This specific type signature is annoying (I'd rather have UnsafeRawPointer, and rather than a separate
/// len I'd like a buffer pointer), but this interface is required because this is passed to an OpenSSL
/// function pointer and so needs to be @convention(c).
internal func openSSLBIOReadFunc(bio: UnsafeMutablePointer<BIO>?, buf: UnsafeMutablePointer<CChar>?, len: CInt) -> CInt {
    guard let concreteBIO = bio, let concreteBuf = buf else {
        preconditionFailure("Invalid pointers in openSSLBIOReadFunc: bio: \(String(describing: bio)) buf: \(String(describing: buf))")
    }

    // This unwrap may fail if the user has dropped the ref to the ByteBufferBIO but still has
    // a ref to the other pointer. Sigh heavily and just fail.
    guard let userPtr = CNIOOpenSSL_BIO_get_data(concreteBIO) else {
        return -1
    }

    // Begin by clearing retry flags. We do this at all OpenSSL entry points.
    CNIOOpenSSL_BIO_clear_retry_flags(concreteBIO)

    // In the event a read for 0 bytes has been asked for, just return early, don't bother with the other work.
    guard len > 0 else {
        return 0
    }

    let swiftBIO: ByteBufferBIO = Unmanaged.fromOpaque(userPtr).takeUnretainedValue()
    let bufferPtr = UnsafeMutableRawBufferPointer(start: concreteBuf, count: Int(len))
    return swiftBIO.sslRead(buffer: bufferPtr)
}

/// The OpenSSL entry point for `puts`. This is a silly function, so we're just going to implement it
/// in terms of write.
///
/// This specific type signature is annoying (I'd rather have UnsafeRawPointer, and rather than a separate
/// len I'd like a buffer pointer), but this interface is required because this is passed to an OpenSSL
/// function pointer and so needs to be @convention(c).
internal func openSSLBIOPutsFunc(bio: UnsafeMutablePointer<BIO>?, buf: UnsafePointer<CChar>?) -> CInt {
    guard let concreteBIO = bio, let concreteBuf = buf else {
        preconditionFailure("Invalid pointers in openSSLBIOPutsFunc: bio: \(String(describing: bio)) buf: \(String(describing: buf))")
    }
    return openSSLBIOWriteFunc(bio: concreteBIO, buf: concreteBuf, len: CInt(strlen(concreteBuf)))
}

/// The OpenSSL entry point for `gets`. This is a *really* silly function and we can't implement it nicely
/// in terms of read, so we just refuse to support it.
///
/// This specific type signature is annoying (I'd rather have UnsafeRawPointer, and rather than a separate
/// len I'd like a buffer pointer), but this interface is required because this is passed to an OpenSSL
/// function pointer and so needs to be @convention(c).
internal func openSSLBIOGetsFunc(bio: UnsafeMutablePointer<BIO>?, buf: UnsafeMutablePointer<CChar>?, len: CInt) -> CInt {
    return -2
}

/// The OpenSSL entry point for `BIO_ctrl`. We don't support most of these.
internal func openSSLBIOCtrlFunc(bio: UnsafeMutablePointer<BIO>?, cmd: CInt, larg: CLong, parg: UnsafeMutableRawPointer?) -> CLong {
    switch cmd {
    case BIO_CTRL_GET_CLOSE:
        return CLong(CNIOOpenSSL_BIO_get_shutdown(bio))
    case BIO_CTRL_SET_CLOSE:
        CNIOOpenSSL_BIO_set_shutdown(bio, CInt(larg))
        return 1
    case BIO_CTRL_FLUSH:
        return 1
    default:
        return 0
    }
}

internal func openSSLBIOCreateFunc(bio: UnsafeMutablePointer<BIO>?) -> CInt {
    return 1
}

internal func openSSLBIODestroyFunc(bio: UnsafeMutablePointer<BIO>?) -> CInt {
    return 1
}


/// An OpenSSL BIO object that wraps `ByteBuffer` objects.
///
/// OpenSSL extensively uses an abstraction called `BIO` to manage its input and output
/// channels. For NIO we want a BIO that operates entirely in-memory, and it's tempting
/// to assume that OpenSSL's `BIO_s_mem` is the best choice for that. However, ultimately
/// `BIO_s_mem` is a flat memory buffer that we end up using as a staging between one
/// `ByteBuffer` of plaintext and one of ciphertext. We'd like to cut out that middleman.
///
/// For this reason, we want to create an object that implements the `BIO` abstraction
/// but which use `ByteBuffer`s to do so. This allows us to avoid unnecessary memory copies,
/// which can be a really large win.
final class ByteBufferBIO {
    /// Pointer to the backing OpenSSL BIO object.
    ///
    /// Generally speaking OpenSSL wants to own the object initialization logic for a BIO.
    /// This doesn't work for us, because we'd like to ensure that the `ByteBufferBIO` is
    /// correctly initialized with all the state it needs. One of those bits of state is
    /// a `ByteBuffer`, which OpenSSL cannot give us, so we need to build our `ByteBufferBIO`
    /// *first* and then use that to drive `BIO` initialization.
    ///
    /// Because of this split initialization dance, we elect to initialize this data structure,
    /// and have it own building an OpenSSL `BIO` structure.
    private let bioPtr: UnsafeMutablePointer<BIO>

    /// The buffer of bytes received from the network.
    ///
    /// By default, `ByteBufferBIO` expects to pass data directly to OpenSSL whenever it
    /// is received. It is, in essence, a temporary container for a `ByteBuffer` on the
    /// read side. This provides a powerful optimisation, which is that the read buffer
    /// passed to the `OpenSSLHandler` can be re-used immediately upon receipt. Given that
    /// the `OpenSSLHandler` is almost always the first handler in the pipeline, this greatly
    /// improves the allocation profile of busy connections, which can more-easily re-use
    /// the receive buffer.
    private var inboundBuffer: ByteBuffer?

    /// The buffer of bytes to send to the network.
    ///
    /// While on the read side `ByteBufferBIO` expects to hold each bytebuffer only temporarily,
    /// on the write side we attempt to coalesce as many writes as possible. This is because a
    /// buffer can only be re-used if it is flushed to the network, and that can only happen
    /// on flush calls, so we are incentivised to write as many SSL_write calls into one buffer
    /// as possible.
    private var outboundBuffer: ByteBuffer

    /// Whether the outbound buffer should be cleared before writing.
    ///
    /// This is true only if we've flushed the buffer to the network. Rather than track an annoying
    /// boolean for this, we use a quick check on the properties of the buffer itself. This clear
    /// wants to be delayed as long as possible to maximise the possibility that it does not
    /// trigger an allocation.
    private var mustClearOutboundBuffer: Bool {
        return outboundBuffer.readerIndex == outboundBuffer.writerIndex && outboundBuffer.readerIndex > 0
    }

    init(allocator: ByteBufferAllocator) {
        // We allocate enough space for a single TLS record. We may not actually write a record that size, but we want to
        // give ourselves the option. We may also write more data than that: if we do, the ByteBuffer will just handle it.
        self.outboundBuffer = allocator.buffer(capacity: SSL_MAX_RECORD_SIZE)

        guard let bio = BIO_new(CNIOOpenSSL_ByteBufferBIOMethod) else {
            preconditionFailure("Unable to initialize custom BIO")
        }

        // We now need to complete the BIO initialization. The BIO does not have an owned pointer
        // to us, as that would create an annoying-to-break reference cycle.
        self.bioPtr = bio
        CNIOOpenSSL_BIO_set_data(self.bioPtr, Unmanaged.passUnretained(self).toOpaque())
        CNIOOpenSSL_BIO_set_init(self.bioPtr, 1)
        CNIOOpenSSL_BIO_set_shutdown(self.bioPtr, 1)
    }

    deinit {
        // On deinit we need to drop our reference to the BIO, and also ensure that it doesn't hold any
        // pointers to this object anymore.
        CNIOOpenSSL_BIO_set_data(self.bioPtr, nil)
        BIO_free(self.bioPtr)
    }

    /// Obtain an owned pointer to the backing OpenSSL BIO object.
    ///
    /// This pointer is safe to use elsewhere, as it has increased the reference to the backing
    /// `BIO`. This makes it safe to use with OpenSSL functions that require an owned reference
    /// (that is, that consume a reference count).
    ///
    /// Note that the BIO may not remain useful for long periods of time: if the `ByteBufferBIO`
    /// object that owns the BIO goes out of scope, the BIO will have its pointers invalidated
    /// and will no longer be able to send/receive data.
    internal func retainedBIO() -> UnsafeMutablePointer<BIO> {
        CNIOOpenSSL_BIO_up_ref(self.bioPtr)
        return self.bioPtr
    }


    /// Called to obtain the outbound ciphertext written by OpenSSL.
    ///
    /// This function obtains a buffer of ciphertext that needs to be written to the network. In a
    /// normal application, this should be obtained on a call to `flush`. If no bytes have been flushed
    /// to the network, then this call will return `nil` rather than an empty byte buffer, to help signal
    /// that the `write` call should be elided.
    ///
    /// - returns: A buffer of ciphertext to send to the network, or `nil` if no buffer is available.
    func outboundCiphertext() -> ByteBuffer? {
        guard self.outboundBuffer.readableBytes > 0 else {
            // No data to send.
            return nil
        }

        /// Once we return from this function, we want to account for the bytes we've handed off.
        defer {
            self.outboundBuffer.moveReaderIndex(to: self.outboundBuffer.writerIndex)
        }

        return self.outboundBuffer
    }

    /// Stores a buffer received from the network for delivery to OpenSSL.
    ///
    /// Whenever a buffer is received from the network, it is passed to the BIO via this function
    /// call. Only one buffer may be passed to OpenSSL at any one time: once a buffer is passed, it
    /// is expected to be cleared immediately. If it is not cleared, this is an application error and
    /// must be resolved.
    ///
    /// - parameters:
    ///     - buffer: The buffer of ciphertext bytes received from the network.
    func receiveFromNetwork(buffer: ByteBuffer) {
        precondition(self.inboundBuffer == nil, "Did not flush inbound bytes to OpenSSL")
        self.inboundBuffer = buffer
    }

    /// OpenSSL has requested to read ciphertext bytes from the network.
    ///
    /// This function is invoked whenever OpenSSL is looking to read data.
    ///
    /// - parameters:
    ///     - buffer: The buffer for NIO to copy bytes into.
    /// - returns: The number of bytes we have copied.
    fileprivate func sslRead(buffer: UnsafeMutableRawBufferPointer) -> CInt {
        guard var inboundBuffer = self.inboundBuffer else {
            // We have no bytes to read. Mark this as "needs read retry".
            CNIOOpenSSL_BIO_set_retry_read(self.bioPtr)
            return -1
        }

        let bytesToCopy = min(buffer.count, inboundBuffer.readableBytes)
        _ = inboundBuffer.readWithUnsafeReadableBytes { bytePointer in
            assert(bytePointer.count >= bytesToCopy, "Copying more bytes (\(bytesToCopy)) than fits in readable bytes \((bytePointer.count))")
            assert(buffer.count >= bytesToCopy, "Copying more bytes (\(bytesToCopy) than contained in source buffer (\(buffer.count))")
            buffer.baseAddress!.copyMemory(from: bytePointer.baseAddress!, byteCount: bytesToCopy)
            return bytesToCopy
        }

        // If we have read all the bytes from the inbound buffer, nil it out.
        if inboundBuffer.readableBytes > 0 {
            self.inboundBuffer = inboundBuffer
        } else {
            self.inboundBuffer = nil
        }

        return CInt(bytesToCopy)
    }

    /// OpenSSL has requested to write ciphertext bytes from the network.
    ///
    /// - parameters:
    ///     - buffer: The buffer for NIO to copy bytes from.
    /// - returns: The number of bytes we have copied.
    fileprivate func sslWrite(buffer: UnsafeRawBufferPointer) -> CInt {
        if self.mustClearOutboundBuffer {
            // We just flushed, and this is a new write. Let's clear the buffer now.
            self.outboundBuffer.clear()
            assert(!self.mustClearOutboundBuffer)
        }

        let writtenBytes = self.outboundBuffer.write(bytes: buffer)
        return CInt(writtenBytes)
    }
}
