# Solvionyx Secure Boot System

Includes:

- PK (Platform Key)
- KEK (Key Exchange Key)
- DB (Signature Database Key)
- Signing tools
- Integration patches for ISO builder

Use "generate_keys.sh" to create keys.
Use "sign.sh" to sign kernel + boot components.
Install keys via MokManager on first boot.
