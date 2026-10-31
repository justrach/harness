# Image annotation

Design note for annotating images before sending them to the agent.

- Click an image (chat or composer) to open a preview.
- Annotate: rectangle and text tools, 4 colors, numbered pins with notes.
- Done flattens into a new attachment and adds the numbered notes as text to the prompt.

Modeled on the Claude desktop annotate flow. Implementation follows in this PR.
