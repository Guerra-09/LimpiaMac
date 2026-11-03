# LimpiaMac

App para macOS (SwiftUI) que libera espacio en disco.

- **Limpieza:** borra cachés, logs, DerivedData de Xcode y otros archivos que se regeneran solos.
- **Explorador de disco:** ve qué ocupa espacio, en lista o en burbujas.
- **Aplicaciones:** desinstala apps junto con sus restos (cachés, preferencias, logs).
- **Varios discos:** elige el disco que quieres revisar, incluidos los externos.

## Requisitos

- macOS 14 o superior
- Xcode instalado (para compilar)

## Instalar

```bash
git clone https://github.com/Guerra-09/LimpiaMac.git
cd LimpiaMac
./build_app.sh
open LimpiaMac.app
```

Si quieres, mueve `LimpiaMac.app` a `/Applications`.

## Permisos

Para leer la Papelera y algunos logs, da **Acceso total al disco** a LimpiaMac en
Ajustes del Sistema → Privacidad y seguridad. Después reinicia la app.

## Aviso

La limpieza borra archivos de forma permanente. Revisa lo que está marcado antes de confirmar.

## Licencia

[MIT](LICENSE)
