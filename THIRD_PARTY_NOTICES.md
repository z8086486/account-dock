# Third-party notices

Account Dock's original code is distributed under the [MIT License](LICENSE).
Third-party components retain their own copyright notices and license terms.

## Sparkle 2.10.0

Account Dock includes Sparkle for in-app updates.

- Project and source: https://github.com/sparkle-project/Sparkle/tree/2.10.0
- License: MIT, with additional notices for bundled components.
- Complete upstream notices: [Sparkle-LICENSE.txt](licenses/Sparkle-LICENSE.txt)

The upstream license file includes the notices for bsdiff/bspatch, sais-lite,
Ed25519, and the other components identified by Sparkle. It is included without
modification in the app at `Contents/Resources/licenses/Sparkle-LICENSE.txt`.

VS Code and the official Codex extension are installed separately and are not
redistributed in Account Dock's app bundle. Their own terms apply.

## markdown-it 14.1.0

The local conversation reader uses markdown-it to render Markdown with raw HTML
and external image loading disabled. No remote scripts are loaded.

- Source: https://github.com/markdown-it/markdown-it/tree/14.1.0
- License: [MIT](licenses/markdown-it-LICENSE.txt)
- Bundled distribution: `markdown-it@14.1.0/dist/markdown-it.min.js`

Bundled browser dependencies (mdurl, uc.micro, linkify-it, punycode.js, entities):
[upstream license notices](licenses/markdown-it-dependencies.txt).

## KaTeX 0.19.1

The conversation reader renders TeX formulas with bundled KaTeX scripts, styles,
and fonts. Rendering is local; no CDN or external requests are used.

- Source: https://github.com/KaTeX/KaTeX/tree/v0.19.1
- License: [MIT](licenses/KaTeX-LICENSE.txt)
- Bundled distribution: `katex@0.19.1/dist` (browser script, CSS, fonts).
