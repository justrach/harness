# Session emoji metadata

`catalog.json` is normalized from **emoji-datasource 16.0.0**, published by
Cal Henderson in [iamcal/emoji-data](https://github.com/iamcal/emoji-data/tree/v16.0.0).
The upstream metadata is MIT licensed; the complete notice is in `LICENSE`.
`SOURCE.json` pins the retrieval URLs and SHA-256 hashes. No emoji artwork or
proprietary app code is included; the operating system renders the Unicode text.

The normalization keeps Unicode `unified` sequences, all `skin_variations`,
`name` and `short_names`, and category/subcategory search terms. It sorts by
upstream `sort_order`, places skin-tone variants after their base emoji and
removes exact duplicate Unicode sequences. Names become sentence-case labels;
aliases and category terms are lowercased with underscores/hyphens treated as
spaces. Smileys & emotion and People & body remain separate browsing categories;
the five standalone skin-tone components appear under People & body. The other
seven browsing categories retain their upstream grouping.

This is an offline catalogue. A pasted single Unicode grapheme is also accepted,
so newer platform-supported emoji do not depend on a catalogue update.
