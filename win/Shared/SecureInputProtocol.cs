using System;
using System.Buffers.Binary;
using System.IO;

namespace ClipboardSync.WindowsInput;

internal enum SecureInputMessageType : byte
{
    ClientHello = 1,
    AgentReady = 2,
    Mouse = 3,
    Keyboard = 4,
    Ping = 5,
    Pong = 6
}

internal readonly record struct SecureInputFrame(
    SecureInputMessageType Type,
    int A = 0,
    int B = 0,
    int C = 0,
    int D = 0)
{
    private const uint Magic = 0x4E495343; // "CSIN" in little-endian byte order.
    private const byte Version = 1;
    internal const int Size = 24;

    internal byte[] Encode()
    {
        var bytes = new byte[Size];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(0, 4), Magic);
        bytes[4] = Version;
        bytes[5] = (byte)Type;
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(8, 4), A);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(12, 4), B);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(16, 4), C);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(20, 4), D);
        return bytes;
    }

    internal static SecureInputFrame Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != Size)
        {
            throw new InvalidDataException($"Secure input frame has {bytes.Length} bytes; expected {Size}.");
        }
        if (BinaryPrimitives.ReadUInt32LittleEndian(bytes[..4]) != Magic)
        {
            throw new InvalidDataException("Secure input frame has an invalid magic value.");
        }
        if (bytes[4] != Version)
        {
            throw new InvalidDataException($"Secure input protocol version {bytes[4]} is unsupported; expected {Version}.");
        }
        if (bytes[6] != 0 || bytes[7] != 0)
        {
            throw new InvalidDataException("Secure input frame reserved bytes must be zero.");
        }
        if (!Enum.IsDefined(typeof(SecureInputMessageType), bytes[5]))
        {
            throw new InvalidDataException($"Secure input message type {bytes[5]} is unsupported.");
        }

        return new SecureInputFrame(
            (SecureInputMessageType)bytes[5],
            BinaryPrimitives.ReadInt32LittleEndian(bytes.Slice(8, 4)),
            BinaryPrimitives.ReadInt32LittleEndian(bytes.Slice(12, 4)),
            BinaryPrimitives.ReadInt32LittleEndian(bytes.Slice(16, 4)),
            BinaryPrimitives.ReadInt32LittleEndian(bytes.Slice(20, 4)));
    }
}

internal static class SecureInputProtocol
{
    internal const string PipePrefix = "ClipboardSync.Input.v1";

    internal static string PipeName(int sessionId) => $"{PipePrefix}.{sessionId}";

    internal static void WriteFrame(Stream stream, SecureInputFrame frame)
    {
        var bytes = frame.Encode();
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    internal static bool TryReadFrame(Stream stream, out SecureInputFrame frame)
    {
        var bytes = new byte[SecureInputFrame.Size];
        var offset = 0;
        while (offset < bytes.Length)
        {
            var count = stream.Read(bytes, offset, bytes.Length - offset);
            if (count == 0)
            {
                if (offset != 0)
                {
                    throw new EndOfStreamException($"Secure input frame ended after {offset} of {bytes.Length} bytes.");
                }
                frame = default;
                return false;
            }
            offset += count;
        }

        frame = SecureInputFrame.Decode(bytes);
        return true;
    }
}
