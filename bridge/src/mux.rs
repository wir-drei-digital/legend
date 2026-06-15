/// Mux frame codec — must byte-match `backend/lib/legend/core/tunnel/mux.ex`.
///
/// Wire format (all big-endian, no alignment):
///   type:u8  stream_id:u32  length:u32  payload:[length bytes]
///
/// Frame types:
///   OPEN   = 1  (no payload)
///   DATA   = 2  (raw bytes)
///   CLOSE  = 3  (no payload)
///   WINDOW = 4  (payload = credit:u32 big-endian)
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const OPEN: u8 = 1;
pub const DATA: u8 = 2;
pub const CLOSE: u8 = 3;
pub const WINDOW: u8 = 4;

#[allow(dead_code)]
pub const INITIAL_WINDOW: u32 = 262_144;

/// Maximum accepted frame payload (1 MiB). Keep in lockstep with mux.ex `@max_frame_payload`.
pub const MAX_FRAME_PAYLOAD: usize = 1_048_576;

/// Header size: 1 (type) + 4 (stream_id) + 4 (length) = 9 bytes.
const HEADER_LEN: usize = 9;

#[derive(Debug)]
pub struct Frame {
    pub typ: u8,
    pub stream_id: u32,
    pub payload: Vec<u8>,
}

/// Read one frame from `r`.  Returns `None` on clean EOF before the header.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> io::Result<Option<Frame>> {
    let mut hdr = [0u8; HEADER_LEN];
    match r.read_exact(&mut hdr).await {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }

    let typ = hdr[0];
    let stream_id = u32::from_be_bytes([hdr[1], hdr[2], hdr[3], hdr[4]]);
    let length = u32::from_be_bytes([hdr[5], hdr[6], hdr[7], hdr[8]]) as usize;

    if length > MAX_FRAME_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame payload exceeds MAX_FRAME_PAYLOAD",
        ));
    }

    let mut payload = vec![0u8; length];
    if length > 0 {
        r.read_exact(&mut payload).await?;
    }

    Ok(Some(Frame {
        typ,
        stream_id,
        payload,
    }))
}

/// Write one frame to `w`.
#[allow(dead_code)]
pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, frame: &Frame) -> io::Result<()> {
    let length = frame.payload.len() as u32;
    let mut hdr = [0u8; HEADER_LEN];
    hdr[0] = frame.typ;
    hdr[1..5].copy_from_slice(&frame.stream_id.to_be_bytes());
    hdr[5..9].copy_from_slice(&length.to_be_bytes());
    w.write_all(&hdr).await?;
    if !frame.payload.is_empty() {
        w.write_all(&frame.payload).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_oversized_frame_header() {
        // type=DATA, stream=1, length = MAX_FRAME_PAYLOAD + 1
        let mut bytes = vec![DATA];
        bytes.extend_from_slice(&1u32.to_be_bytes());
        bytes.extend_from_slice(&((MAX_FRAME_PAYLOAD + 1) as u32).to_be_bytes());
        let mut cursor = std::io::Cursor::new(bytes);
        assert!(read_frame(&mut cursor).await.is_err());
    }
}
