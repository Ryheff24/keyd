#import "UDPChunker.h"
#import <os/log.h>
#import <string.h>
#import <stdlib.h>

static os_log_t chunker_log(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.ryheff.keyd.remote.agent", "UDPChunker");
    });
    return log;
}

void chunk_frame(const void *frame_data,
                 size_t frame_len,
                 uint16_t seq,
                 size_t mtu,
                 const MediaFrameHeader *original_header,
                 void (^callback)(const void *chunk, size_t chunk_len))
{
    if (!frame_data || !original_header || !callback) return;

    /* Maximum payload per chunk = MTU minus header overhead */
    const size_t header_size = sizeof(MediaFrameHeader);
    if (mtu <= header_size) {
        os_log_error(chunker_log(), "MTU %zu too small for header (%zu bytes)", mtu, header_size);
        return;
    }

    const size_t max_payload = mtu - header_size;

    /* Calculate total number of chunks needed */
    size_t chunk_total;
    if (frame_len == 0) {
        chunk_total = 1; /* Send at least one chunk even for empty frames */
    } else {
        chunk_total = (frame_len + max_payload - 1) / max_payload;
    }

    /* chunk_total must fit in uint16_t (max 65535) */
    if (chunk_total > 65535) {
        os_log_error(chunker_log(),
                     "Frame too large for chunking: %zu bytes needs %zu chunks (max 65535).",
                     frame_len, chunk_total);
        return;
    }

    static int logCount = 0;
    if (logCount < 5) {
        os_log(chunker_log(),
               "Chunking frame seq=%u: %zu bytes -> %zu chunks (MTU=%zu, max_payload=%zu)",
               seq, frame_len, chunk_total, mtu, max_payload);
        logCount++;
    }

    const uint8_t *src = (const uint8_t *)frame_data;
    size_t remaining = frame_len;

    for (size_t i = 0; i < chunk_total; i++) {
        size_t chunk_payload_len = (remaining < max_payload) ? remaining : max_payload;
        size_t packet_len = header_size + chunk_payload_len;

        /* Allocate packet: header + payload */
        uint8_t *packet = malloc(packet_len);
        if (!packet) {
            os_log_error(chunker_log(), "malloc failed for chunk %zu", i);
            return;
        }

        /* Build header for this chunk */
        MediaFrameHeader hdr;
        memcpy(&hdr, original_header, sizeof(MediaFrameHeader));

        hdr.seq = seq;
        hdr.chunk_idx = (uint16_t)i;
        hdr.chunk_total = (uint16_t)chunk_total;
        hdr.payload_size = (uint32_t)chunk_payload_len;

        /* First chunk inherits all flags from original (HEVC, KEYFRAME, DELTA, etc.).
         * Subsequent chunks only carry structural flags. */
        if (i == 0) {
            hdr.flags = original_header->flags;
        } else {
            /* Clear content flags, keep only what's needed for reassembly */
            hdr.flags = original_header->flags & (KEYDRD_FLAG_HEVC);
        }

        /* Set LAST_CHUNK flag only on the final chunk */
        if (i == chunk_total - 1) {
            hdr.flags |= KEYDRD_FLAG_LAST_CHUNK;
        } else {
            hdr.flags &= ~KEYDRD_FLAG_LAST_CHUNK;
        }

        /* Copy header + payload into packet */
        memcpy(packet, &hdr, header_size);
        if (chunk_payload_len > 0) {
            memcpy(packet + header_size, src, chunk_payload_len);
        }

        /* Deliver chunk */
        callback(packet, packet_len);

        free(packet);

        src += chunk_payload_len;
        remaining -= chunk_payload_len;
    }
}
