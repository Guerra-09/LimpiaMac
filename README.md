# LimpiaMac

App para macOS (SwiftUI) que libera espacio en disco.

- **Limpieza:** cachés, logs, DerivedData de Xcode y otros archivos que se regeneran solos.
- **Explorador de disco:** qué ocupa espacio, en lista o en burbujas.
- **Aplicaciones:** desinstala apps con sus restos y busca restos de apps ya borradas.
- **Desarrollo:** `node_modules`, `Pods`, venv y similares; limpieza de Docker.
- **Archivos:** archivos grandes y antiguos, y duplicados exactos.
- **Descargas y backups:** instaladores viejos y copias de seguridad de iPhone.
- **Fotos parecidas:** en tu biblioteca de Fotos o en una carpeta.
- **Sistema:** limpieza automática, uso de memoria y snapshots de Time Machine.
- **Varios discos:** elige el disco a revisar, incluidos los externos.
- **Barra de menú:** espacio libre, memoria y aviso de poco espacio.

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
