# Templates

Put `.fudehand` project files in this directory and rebuild (`pnpm dev` or `pnpm build:native`); each then appears in the launch window's Templates (模板) section.

Creating from a template gives an untitled design document that is not linked to the template file; saving asks for a location. The build script copies only `.fudehand` files, so this README does not end up in the App bundle.

## Bundled starter templates

`Mobile App`, `Web Page`, and `Dashboard` follow [Design foundations](../../../docs/design-foundations.md) and show them in a "Design system" frame. `BundledTemplateTests` checks that each one opens and uses only those values, so a new template must too, or the test's expected list and values must change with the foundations.

## Names

A template is named after its file, in US English. The file name is also a key in the four `Localizable.strings` tables, so add an entry for each new template (`BundledTemplateTests` fails without one); a template without an entry shows its file name in every language.
