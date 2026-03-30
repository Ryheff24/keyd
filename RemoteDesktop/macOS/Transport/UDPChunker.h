#pragma once

#import <Foundation/Foundation.h>
#import "protocol.h"

/**
 * UDP frame chunker for HEVC media transport.
 *
 * Splits frame payloads that exceed UDP MTU into multiple chunks,
 * each with its own MediaFrameHeader. The receiver reassembles
 * chunks by matching `seq` and collecting `chunk_total` pieces.
 *
 * Default MTU: 1200 bytes (safe for Wi-Fi). USB NCM can use 8000.
 */

/** MTU for Wi-Fi — must fit within DTLS record limit (~1400 bytes).
 *  DTLS over Wi-Fi rejects datagrams larger than path MTU.
 *  Max payload per chunk = 1400 - 24 (header) = 1376 bytes.
 *  Max frame size = 255 * 1376 = ~350KB (constrain HEVC bitrate accordingly). */
#define KEYDRD_MTU_WIFI  1400

/** MTU for USB NCM (larger packets OK over wired link) */
#define KEYDRD_MTU_USB   8000

/**
 * Chunk a frame and deliver each chunk via callback.
 *
 * @param frame_data   Raw frame payload (compressed HEVC/LZ4 data, NOT including header).
 * @param frame_len    Length of frame_data in bytes.
 * @param seq          Frame sequence number (shared across all chunks).
 * @param mtu          Maximum transmission unit (total packet size including header).
 * @param original_header  Pointer to the original MediaFrameHeader for this frame.
 *                         Flags, timestamp, and CRC are copied from this header.
 *                         chunk_idx and chunk_total are overwritten per chunk.
 * @param callback     Called once per chunk with (complete packet including header, packet length).
 *                     The pointer is only valid for the duration of the callback.
 */
void chunk_frame(const void *frame_data,
                 size_t frame_len,
                 uint16_t seq,
                 size_t mtu,
                 const MediaFrameHeader *original_header,
                 void (^callback)(const void *chunk, size_t chunk_len));
