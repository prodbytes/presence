# Theme

The colors follow **Gruvbox dark, soft contrast**, defined in
[lib/theme.dart](../presence_app/lib/theme.dart):

| Role | Gruvbox color | Hex |
|------|---------------|-----|
| Page background | bg0_s | `#32302f` |
| Panels | bg1 | `#3c3836` |
| Event cards, header buttons, dividers | bg2 | `#504945` |
| Camera tile background | bg0_h | `#1d2021` |
| Text | fg | `#ebdbb2` |
| Secondary text | fg4 | `#a89984` |
| Primary accent (app title, event icons, spinners) | yellow | `#fabd2f` |
| Secondary accent | aqua | `#8ec07c` |
| Errors | red | `#fb4934` |

The web manifest's `theme_color` and `background_color` are also `#32302f`.

## Layout components

The theme also sets the look of the layout's components, the same on every
screen (`gruvboxSoftDarkTheme`):

- **App bar** (`appBarTheme`): flat (no elevation, no tint when content
  scrolls under it), the page's background, its title **left-aligned and
  bold** (22 sp, weight 700, fg).
- **Bottom navigation bar** (`navigationBarTheme`): flat, 64 dp, the
  page's background, every label shown (12 sp, cut short with an
  ellipsis). **No indicator pill**: the open tab's icon and label are
  yellow, its label bold; the others fg4. See
  [Navigation](navigation.md).
- **Snackbars** float (`SnackBarBehavior.floating`), above the navigation
  bar instead of covering it.
