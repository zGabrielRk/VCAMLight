# VCAMLight

Overlay minimalista de câmera virtual. Sem login, sem wallet, sem session.

## Funcionalidade

- **Volume +/-** → abre/fecha overlay
- **Select** → escolhe vídeo da galeria (PHPickerViewController)
- **Preview** → pré-visualiza o vídeo selecionado
- **Apply** → injeta o vídeo como câmera virtual em todos os apps

## Como compilar (macOS com Theos)

### 1. Instalar Theos
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

### 2. Clonar e compilar
```bash
cd VCAMLight
make package
```

### 3. Instalar no device
```bash
make install THEOS_DEVICE_IP=<ip-do-iphone>
```

Ou copie o `.deb` da pasta `packages/` para o iPhone e instale via Sileo/Zebra.

## Estrutura do projeto

```
VCAMLight/
├── Makefile          # configuração Theos
├── control           # metadados do pacote
├── VCAMLight.plist   # filtro de injeção (SpringBoard + mediaserverd)
├── Tweak.xm          # hooks de volume e câmera (Logos)
├── VCAMOverlay.h     # header da overlay
└── VCAMOverlay.mm    # UI da overlay (UIKit + PhotosUI)
```

## Como funciona

### SpringBoard (Volume Hook)
```
Volume +/- → SBVolumeControl.increaseVolume/decreaseVolume → [VCAMOverlay toggle]
```

### VCAMOverlay (UI)
```
toggle → UIWindow com card animado
       → Select → PHPickerViewController → copia vídeo para /var/tmp/com.apple.avfcache/selected.mov
       → Apply  → escreve prefs.plist + Darwin notify → mediaserverd recarrega
```

### mediaserverd (Câmera)
```
Darwin notify → vcam_setupReader(path) → AVAssetReader começa a ler frames
AVCaptureOutput hook → injeta frames do vídeo no lugar da câmera real
```

## Configurações em prefs.plist

| Chave    | Tipo    | Descrição                        |
|----------|---------|----------------------------------|
| replOn   | BOOL    | Substituição ativa               |
| loopOn   | BOOL    | Loop do vídeo                    |
| galName  | String  | Caminho do vídeo selecionado     |
| mode     | String  | "gallery" ou "stream"            |
