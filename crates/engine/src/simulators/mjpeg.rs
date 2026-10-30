//! A `multipart/x-mixed-replace` JPEG stream, split into frames.
//!
//! The hub writes each frame as a part with a `Content-Length` header:
//! `--frame\r\nContent-Type: image/jpeg\r\nContent-Length: N\r\n\r\n<N bytes>\r\n`.
//! Bytes arrive in arbitrary chunks, so the parser buffers until a whole part
//! is in hand.

/// Larger than any frame the hub sends at the engine's downscale; a part that
/// claims more is treated as a broken stream rather than buffered.
const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

#[derive(Default)]
pub(crate) struct MjpegParser {
    buf: Vec<u8>,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ParseError {
    /// A part header without a usable `Content-Length`, or one past the cap.
    BadPart,
}

impl MjpegParser {
    /// Feed a chunk; returns every frame it completed, oldest first.
    pub(crate) fn push(&mut self, chunk: &[u8]) -> Result<Vec<Vec<u8>>, ParseError> {
        self.buf.extend_from_slice(chunk);
        let mut frames = Vec::new();
        loop {
            let Some(header_end) = find(&self.buf, b"\r\n\r\n") else {
                // A header never runs this long; a stream that never sends one is broken.
                if self.buf.len() > 64 * 1024 && find(&self.buf, b"Content-Length").is_none() {
                    return Err(ParseError::BadPart);
                }
                break;
            };
            let length = content_length(&self.buf[..header_end]).ok_or(ParseError::BadPart)?;
            if length > MAX_FRAME_BYTES {
                return Err(ParseError::BadPart);
            }
            let body_start = header_end + 4;
            if self.buf.len() < body_start + length {
                break;
            }
            frames.push(self.buf[body_start..body_start + length].to_vec());
            self.buf.drain(..body_start + length);
        }
        Ok(frames)
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// `Content-Length` from a part's header block (which may start with the
/// previous part's trailing CRLF and the boundary line).
fn content_length(header: &[u8]) -> Option<usize> {
    let text = std::str::from_utf8(header).ok()?;
    text.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim()
            .eq_ignore_ascii_case("content-length")
            .then(|| value.trim().parse().ok())?
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn part(body: &[u8]) -> Vec<u8> {
        let mut out = format!(
            "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .into_bytes();
        out.extend_from_slice(body);
        out.extend_from_slice(b"\r\n");
        out
    }

    #[test]
    fn frames_split_across_chunks_come_out_whole_and_in_order() {
        let mut stream = part(b"\xff\xd8one\xff\xd9");
        stream.extend(part(b"\xff\xd8second\xff\xd9"));
        stream.extend(part(b"\xff\xd8three\xff\xd9"));
        let mut parser = MjpegParser::default();
        let mut frames = Vec::new();
        for chunk in stream.chunks(7) {
            frames.extend(parser.push(chunk).unwrap());
        }
        assert_eq!(
            frames,
            vec![
                b"\xff\xd8one\xff\xd9".to_vec(),
                b"\xff\xd8second\xff\xd9".to_vec(),
                b"\xff\xd8three\xff\xd9".to_vec(),
            ]
        );
    }

    #[test]
    fn a_part_without_a_length_or_past_the_cap_breaks_the_stream() {
        let mut parser = MjpegParser::default();
        assert_eq!(
            parser.push(b"--frame\r\nContent-Type: image/jpeg\r\n\r\nxx"),
            Err(ParseError::BadPart)
        );
        let mut parser = MjpegParser::default();
        let huge = format!("--frame\r\nContent-Length: {}\r\n\r\n", MAX_FRAME_BYTES + 1);
        assert_eq!(parser.push(huge.as_bytes()), Err(ParseError::BadPart));
    }
}
