//! legend-bridge — loopback reverse-tunnel bridge.
//!
//! Two listeners, both bound ONCE at startup:
//!   Control  127.0.0.1:9000  — the backend (carrier) connects here.
//!   Data     127.0.0.1:7777  — the in-sprite agent HTTP client connects here.
//!
//! A data connection becomes one mux stream over the currently active carrier.
//! When no carrier is connected the data connection is dropped immediately
//! (the agent is expected to retry).
//!
//! Mux wire format matches `backend/lib/legend/core/tunnel/mux.ex` exactly:
//!   type:u8  stream_id:u32  length:u32  payload:[length bytes]  (big-endian)
//!
//! WINDOW frames are decoded and emitted in the codec but backpressure in this
//! v1 implementation relies entirely on bounded mpsc channels; inbound WINDOW
//! frames from the carrier are accepted and discarded (no-op).

mod mux;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::io::{AsyncWriteExt, ReadHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

/// Payload capacity for the outbound (bridge → carrier) queue.
const OUTBOUND_QUEUE: usize = 256;

/// Payload capacity per stream's inbound (carrier → agent) queue.
const STREAM_QUEUE: usize = 64;

/// A new agent connection to be muxed over the carrier.
struct NewStream {
    stream_id: u32,
    socket: TcpStream,
}

/// Per-stream sender: bytes coming from the carrier go here → forwarded to agent.
type StreamSenders = Arc<Mutex<HashMap<u32, mpsc::Sender<Vec<u8>>>>>;

/// Outbound frame bytes to be written to the carrier.
type OutboundTx = mpsc::Sender<Vec<u8>>;

/// The "current carrier" new-stream injection channel.
/// The data-accept task holds an Arc and writes NewStream requests whenever an
/// agent connects.  The carrier-session loop replaces the inner value each time
/// a new carrier connects.
type CarrierInboundTx = Arc<Mutex<Option<mpsc::Sender<NewStream>>>>;

#[tokio::main]
async fn main() {
    let control_addr = "127.0.0.1:9000";
    let data_addr = "127.0.0.1:7777";

    // Bind BOTH listeners once — the data listener must not be re-bound in the
    // carrier-reconnect loop (fixes the double-bind bug in the planning sketch).
    let control_listener = TcpListener::bind(control_addr)
        .await
        .unwrap_or_else(|e| panic!("cannot bind control {control_addr}: {e}"));
    let data_listener = TcpListener::bind(data_addr)
        .await
        .unwrap_or_else(|e| panic!("cannot bind data {data_addr}: {e}"));

    println!("[bridge] control listener on {control_addr}");
    println!("[bridge] data    listener on {data_addr}");

    // Shared: data-accept task injects new agent connections into whoever the
    // current carrier session is.
    let carrier_inbound_tx: CarrierInboundTx = Arc::new(Mutex::new(None));

    // Long-lived data-accept task — never exits; bound to `data_listener` only.
    let cit_clone = carrier_inbound_tx.clone();
    let mut next_stream_id: u32 = 1;
    tokio::spawn(async move {
        loop {
            match data_listener.accept().await {
                Err(e) => {
                    eprintln!("[bridge] data accept error: {e}");
                    continue;
                }
                Ok((socket, peer)) => {
                    let sid = next_stream_id;
                    next_stream_id = next_stream_id.wrapping_add(1);
                    println!("[bridge] agent connected {peer}, stream_id={sid}");

                    let maybe_tx = cit_clone.lock().unwrap().clone();
                    match maybe_tx {
                        Some(tx) => {
                            // Non-blocking: if the carrier queue is full, drop.
                            if tx
                                .try_send(NewStream {
                                    stream_id: sid,
                                    socket,
                                })
                                .is_err()
                            {
                                eprintln!(
                                    "[bridge] carrier busy or disconnected, dropping agent {peer}"
                                );
                            }
                        }
                        None => {
                            eprintln!("[bridge] no carrier, dropping agent {peer}");
                        }
                    }
                }
            }
        }
    });

    // Carrier-reconnect loop: accept one control connection at a time.
    loop {
        println!("[bridge] waiting for carrier on {control_addr} …");
        let (carrier, peer) = match control_listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                eprintln!("[bridge] control accept error: {e}");
                continue;
            }
        };
        println!("[bridge] carrier connected from {peer}");

        run_carrier_session(carrier, carrier_inbound_tx.clone()).await;

        println!("[bridge] carrier {peer} disconnected, waiting for next");
    }
}

/// Run one mux session over `carrier`.  Returns when the carrier disconnects.
async fn run_carrier_session(carrier: TcpStream, carrier_inbound_tx: CarrierInboundTx) {
    // Channel for new agent connections during this carrier session.
    let (new_stream_tx, mut new_stream_rx) = mpsc::channel::<NewStream>(64);
    // Channel for outbound frames (bridge → carrier).
    let (out_tx, mut out_rx) = mpsc::channel::<Vec<u8>>(OUTBOUND_QUEUE);

    // Install the new-stream sender so the data-accept task can reach us.
    {
        let mut guard = carrier_inbound_tx.lock().unwrap();
        *guard = Some(new_stream_tx);
    }

    // Per-stream senders: carrier → agent.
    let stream_senders: StreamSenders = Arc::new(Mutex::new(HashMap::new()));

    let (carrier_read, mut carrier_write) = tokio::io::split(carrier);

    // --- Writer task: drain out_rx → carrier TCP socket ---
    let writer_task = tokio::spawn(async move {
        while let Some(bytes) = out_rx.recv().await {
            if carrier_write.write_all(&bytes).await.is_err() {
                break;
            }
        }
        // Attempt graceful shutdown.
        let _ = carrier_write.shutdown().await;
    });

    // --- Reader task: read frames from carrier, dispatch to per-stream tasks ---
    let senders_r = stream_senders.clone();
    let out_tx_r = out_tx.clone();
    let reader_task = tokio::spawn(async move {
        carrier_reader(carrier_read, senders_r, out_tx_r).await;
    });

    // --- Main session loop: wire up new agent connections ---
    while let Some(NewStream {
        stream_id: sid,
        socket,
    }) = new_stream_rx.recv().await
    {
        // Guard: don't start a stream if the carrier is already gone.
        if out_tx.is_closed() {
            eprintln!("[bridge] carrier gone, dropping stream {sid}");
            break;
        }

        let (inbound_tx, inbound_rx) = mpsc::channel::<Vec<u8>>(STREAM_QUEUE);
        {
            let mut guard = stream_senders.lock().unwrap();
            guard.insert(sid, inbound_tx);
        }

        // Send OPEN frame to carrier.
        let open_frame = encode_frame(mux::OPEN, sid, &[]);
        if out_tx.send(open_frame).await.is_err() {
            eprintln!("[bridge] carrier gone while sending OPEN for stream {sid}");
            break;
        }

        // Spawn a bidirectional splice task for this stream.
        let out_tx2 = out_tx.clone();
        let senders2 = stream_senders.clone();
        tokio::spawn(async move {
            splice_stream(sid, socket, inbound_rx, out_tx2, senders2).await;
        });
    }

    // Clean up: clear the carrier sender so data-accept drops new conns.
    {
        let mut guard = carrier_inbound_tx.lock().unwrap();
        *guard = None;
    }

    // Abort background tasks; they will stop when out_tx / carrier_read are dropped.
    reader_task.abort();
    writer_task.abort();
    let _ = reader_task.await;
    let _ = writer_task.await;

    // Drop all remaining stream senders so their splice tasks exit.
    stream_senders.lock().unwrap().clear();
}

/// Read frames from the carrier and dispatch to per-stream tasks.
async fn carrier_reader(
    mut r: ReadHalf<TcpStream>,
    stream_senders: StreamSenders,
    out_tx: OutboundTx,
) {
    loop {
        match mux::read_frame(&mut r).await {
            Err(e) => {
                eprintln!("[bridge] carrier read error: {e}");
                break;
            }
            Ok(None) => {
                println!("[bridge] carrier EOF");
                break;
            }
            Ok(Some(frame)) => {
                match frame.typ {
                    mux::DATA => {
                        let maybe_tx = {
                            let guard = stream_senders.lock().unwrap();
                            guard.get(&frame.stream_id).cloned()
                        };
                        if let Some(tx) = maybe_tx {
                            if tx.send(frame.payload).await.is_err() {
                                eprintln!("[bridge] stream {} gone", frame.stream_id);
                            }
                        } else {
                            eprintln!("[bridge] DATA for unknown stream {}", frame.stream_id);
                        }
                    }
                    mux::CLOSE => {
                        // Remove the sender; the splice task will see the channel
                        // close and shut down its half.
                        let mut guard = stream_senders.lock().unwrap();
                        guard.remove(&frame.stream_id);
                    }
                    mux::OPEN => {
                        // Carrier should not send OPEN to us (we initiate streams).
                        eprintln!("[bridge] unexpected OPEN from carrier (ignored)");
                    }
                    mux::WINDOW => {
                        // v1: WINDOW frames are no-ops; backpressure via bounded mpsc.
                    }
                    other => {
                        eprintln!("[bridge] unknown frame type {other}, ignoring");
                    }
                }
            }
        }
    }

    // Signal the outbound queue to stop by dropping out_tx here — writer will flush & exit.
    drop(out_tx);
}

/// Bidirectional splice between one agent TCP socket and the mux carrier.
///
/// agent → carrier: read agent bytes, emit DATA frames to out_tx.
/// carrier → agent: drain inbound_rx, write bytes to agent socket.
async fn splice_stream(
    stream_id: u32,
    socket: TcpStream,
    mut inbound_rx: mpsc::Receiver<Vec<u8>>,
    out_tx: OutboundTx,
    stream_senders: StreamSenders,
) {
    let (mut agent_read, mut agent_write) = tokio::io::split(socket);

    let out_tx_w = out_tx.clone();
    // agent → carrier task.
    let a2c = tokio::spawn(async move {
        let mut buf = vec![0u8; 8192];
        loop {
            match tokio::io::AsyncReadExt::read(&mut agent_read, &mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let frame = encode_frame(mux::DATA, stream_id, &buf[..n]);
                    if out_tx_w.send(frame).await.is_err() {
                        break;
                    }
                }
            }
        }
        // Agent closed its write side — tell carrier.
        let close_frame = encode_frame(mux::CLOSE, stream_id, &[]);
        let _ = out_tx_w.send(close_frame).await;
    });

    // carrier → agent task.
    let c2a = tokio::spawn(async move {
        while let Some(data) = inbound_rx.recv().await {
            if agent_write.write_all(&data).await.is_err() {
                break;
            }
        }
        let _ = agent_write.shutdown().await;
    });

    // Wait for both directions; whichever finishes first, abort the other.
    tokio::select! {
        _ = a2c => {}
        _ = c2a => {}
    }

    // Clean up stream registration.
    stream_senders.lock().unwrap().remove(&stream_id);
}

/// Encode a mux frame into raw bytes (ready to send over the carrier).
#[inline]
fn encode_frame(typ: u8, stream_id: u32, payload: &[u8]) -> Vec<u8> {
    let length = payload.len() as u32;
    let mut out = Vec::with_capacity(9 + payload.len());
    out.push(typ);
    out.extend_from_slice(&stream_id.to_be_bytes());
    out.extend_from_slice(&length.to_be_bytes());
    out.extend_from_slice(payload);
    out
}
