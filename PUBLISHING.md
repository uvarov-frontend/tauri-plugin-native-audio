# Publishing

## 1) Preflight checks

From plugin repo root:

```bash
cargo check
cargo package
```

From `guest-js/`:

```bash
npm pack --dry-run
```

## 2) Version bump

- Bump crate version in `Cargo.toml`.
- Bump npm version in `guest-js/package.json`.
- Commit and tag release:

```bash
git add .
git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

## 3) Publish Rust crate

```bash
cargo login
cargo publish
```

## 4) Publish npm package

```bash
cd guest-js
npm login
npm publish
```
