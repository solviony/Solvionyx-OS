# 🧩 Solvionyx OS — Aurora Series  
### *Next-generation Linux experience built for creators, developers, and everyday users.*

---

## 🚀 Overview  
**Solvionyx OS** is a modern, Debian-based operating system focused on performance, creativity, and automation.  
The Aurora series introduces a powerful **multi-edition architecture**, supporting developers, producers, and general users with tailored environments.

---

## 🖥️ Editions  

| Edition | Desktop | Description |
|----------|----------|-------------|
| **Aurora (Production)** | GNOME | Stable release for general use — sleek, productive, and user-friendly. |
| **Aurora Lite (Developer)** | XFCE | Lightweight edition optimized for coding, testing, and development. |
| **Aurora Studio (Experimental)** | KDE Plasma | Creative suite edition for video, 3D, and multimedia production. |

---

## 🧠 Features  
- Built on **Debian 12 (Bookworm)**  
- Integrated **QEMU GUI smoke test** with screenshots  
- **Automated build + GitHub release pipeline**  
- Built-in **Calamares installer**, **Plymouth animation**, and **Solvionyx Welcome App**  
- Per-edition changelogs and release notes  
- Optimized hardware detection (Intel / AMD / NVIDIA)  

---

## ⚙️ Automated Build System  
Solvionyx OS can be built and released automatically using a single command:

```bash
bash <(curl -fsSL https://gist.githubusercontent.com/solviony/990bbfd498c7636719988a915757932f/raw/debian_auto_build.sh)
```

This will:  
✅ Build GNOME, XFCE, and KDE editions  
✅ Run QEMU GUI smoke tests (with screenshots)  
✅ Generate changelogs automatically  
✅ Upload all builds to GitHub Releases  

> 🔐 Make sure you’ve authenticated with GitHub CLI:
> ```bash
> gh auth login
> ```

---

## 🧩 Developer Guide  
For full details on the automation pipeline, including setup, changelog generation, and GitHub release process, see:  
📄 **[BUILD_AUTOMATION_GUIDE.md](./BUILD_AUTOMATION_GUIDE.md)**  

---

## 🧾 Credits  
- **Lead Developer:** Maurice Joway (`@solviony`)  
- **Project:** Solvionyx OS — Aurora Series  
- **Base:** Debian 12 (Bookworm)  
- **Automation:** ChatGPT x Solvionyx Labs  
