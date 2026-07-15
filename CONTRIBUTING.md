# Contributing

[← Back to README](README.md)

## Code Style

- Swift-only codebase with 2-space indentation
- Follow SwiftLint rules
- Small, testable functions with dependency injection
- Avoid over-engineering - keep solutions simple and focused

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes using [Conventional Commits](https://www.conventionalcommits.org/)
   - `feat: add calendar event deduplication`
   - `fix: handle device disconnect gracefully`
   - `docs: update Google OAuth setup instructions`
4. Push to your branch
5. Open a Pull Request with:
   - Purpose and motivation
   - Screenshots for UI changes
   - Documentation updates

## Security

- Never commit Google credentials, API tokens, or device passwords
- Credentials are stored in macOS Keychain

For build and test commands, see [Installation](docs/installation.md#building-and-testing).
