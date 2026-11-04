# Japanese games and visual novels

Many Japanese PC games, visual novels above all, keep their text in Shift-JIS
(Windows code page 932) and draw it with MS Gothic, MS Mincho or MS UI Gothic.
When the iPhone is set to another language, Wine runs them with an English or
European code page and none of those fonts exist, so:

- text shows as gibberish (mojibake) or as empty squares, or does not show at all;
- some games do not start at all, because a file name, a script or a resource
  name cannot be converted.

## Turning it on

**Game details › Compatibility › Japanese locale**, for each game that needs it.
It applies the next time the game starts.

The same switch can be written by hand, for one game in **Game details › This
game's config** or for every game in `Documents/madeira.cfg`:

```text
env.MADEIRA_JAPANESE = 1
```

## What it does

| Part | Effect |
|---|---|
| Locale | `LC_ALL = ja_JP.UTF-8`: Wine's system and user locale are Japanese (ja-JP), so the ANSI and OEM code pages are 932 (Shift-JIS). A Japanese `env.LC_ALL` already in the game's config is kept. |
| Code page tables | `env.MADEIRA_NLS_EXTRA = 1`: Wine's `c_932.nls` (and the other CJK tables, plus `c_10000.nls`, Mac Roman, which Wine's font code asks for when it reads font names) are loaded from the app's `nls/extra` folder. Without them code page 932 does not exist in Madeira. |
| Font | The bundled **Noto Sans JP** (SIL Open Font License 1.1) is copied into the prefix's `C:\windows\Fonts`. |
| Font names | `HKCU\Software\Wine\Fonts\Replacements` maps MS Gothic, MS PGothic, MS UI Gothic, MS Mincho, MS PMincho, Meiryo, Yu Gothic, Yu Mincho and their Japanese names (ＭＳ ゴシック, ＭＳ 明朝 …) onto Noto Sans JP. A replacement only applies while no real font of that name is installed, so a game that brings its own fonts keeps them. |

The font and the font names stay in the prefix once written. Other games only
see them when they ask for one of those Japanese font names or draw Japanese
text. The locale and code page are set only for games that have the switch on.

The log shows `[japanese]` lines for each step.

## Known limits

- Mincho (serif) names are mapped to the same sans-serif font; the text is
  readable but does not look like Mincho.
- MS Gothic is a fixed-pitch font and Noto Sans JP is not. A game that lays out
  half-width Latin text in fixed columns can show it slightly misaligned. If a
  game needs the real metrics, installing a fixed-pitch Japanese font (for
  example IPAGothic) into `C:\windows\Fonts` takes precedence over the mapping.
- Text inside the game's own images is not affected.
