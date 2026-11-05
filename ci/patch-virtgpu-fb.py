#!/usr/bin/env python3
"""Patcht den virtio-gpu-fbdev des Android-4.4-Kernels, damit KitKat-gralloc/surfaceflinger darauf laeuft.

Aufruf: python3 ci/patch-virtgpu-fb.py linux/drivers/gpu/drm/virtio/virtgpu_fb.c

Problem (Boot haengt, system_server wartet ewig auf SurfaceFlinger):
  surfaceflinger steckt dauerhaft in gralloc mapFrameBufferLocked() -> memset() auf /dev/graphics/fb0.
  Der virtio-gpu-fbdev hat KEIN fb_mmap und setzt fix.smem_start nie (=0). Der generische fb_mmap()
  mappt dann vm_iomap_memory(vma, smem_start=0, smem_len) = PHYSISCHE ADRESSE 0 (unbelegter Bereich
  der virt-Maschine) statt des Framebuffers. Jeder Schreibzugriff laeuft als langsamer MMIO-Zugriff
  ins Leere (surfaceflinger rechnet minutenlang, nichts erscheint je auf dem Bildschirm).

Aenderungen:
  1. DOUBLE_BUFFER_PATCH  Puffer 2*Bildschirmhoehe (gralloc-Page-Flipping braucht yres_virtual >= 2*yres).
  2. SMEM_LEN_PATCH       fix.smem_len = Puffergroesse (gralloc bricht sonst bei smem_len <= 0 ab).
  3. FBDEV_MMAP_PATCH     eigenes fb_mmap: Seiten des GEM-Objekts (TTM) in den User-Adressraum einblenden.
  4. FBDEV_PAN_PATCH      eigenes fb_pan_display + fb_set_par: gralloc schaltet pro Frame per
                          FBIOPUT_VSCREENINFO (yoffset) um. Der Userspace schreibt direkt in den mmap-Puffer,
                          der Treiber merkt davon nichts -> hier Scanout auf den sichtbaren Puffer legen,
                          sichtbaren Bereich zum Host uebertragen und flushen (sonst bleibt das VNC-Bild schwarz).
"""
import re
import sys

path = sys.argv[1]
s = open(path).read()


def fail(msg):
    sys.stderr.write("FEHLER: " + msg + "\n")
    for i, line in enumerate(s.splitlines(), 1):
        if re.search(r"screen_size|screen_base|screen_buffer|mode_cmd\.height|virtio_gpufb_ops|fb_pan_display|fb_set_par", line):
            sys.stderr.write("  %d: %s\n" % (i, line))
    sys.exit(1)


# 1. Doppelpuffer -------------------------------------------------------------------------------------
if "DOUBLE_BUFFER_PATCH" not in s:
    s, n = re.subn(r"^(\s*)mode_cmd\.height = sizes->surface_height;",
                   r"\1mode_cmd.height = sizes->surface_height * 2; /* DOUBLE_BUFFER_PATCH */",
                   s, count=1, flags=re.M)
    if n != 1:
        fail("mode_cmd.height-Zeile nicht gefunden")

# 2. smem_len -----------------------------------------------------------------------------------------
if "SMEM_LEN_PATCH" not in s:
    s, n = re.subn(r"^(\s*)(info->screen_size = [^;]*;)",
                   r"\1\2\n\1info->fix.smem_len = info->screen_size; /* SMEM_LEN_PATCH */",
                   s, count=1, flags=re.M)
    if n != 1:
        fail("info->screen_size-Zeile nicht gefunden")

# 3. + 4. mmap / pan / set_par ------------------------------------------------------------------------
FUNCS = r'''
/* FBDEV_MMAP_PATCH: Seiten des Framebuffer-Objekts direkt in den User-Adressraum einblenden.
 * (Ohne diese Funktion mappt fb_mmap() die physische Adresse smem_start=0, nicht den Puffer.) */
static int virtio_gpufb_mmap(struct fb_info *info, struct vm_area_struct *vma)
{
	struct virtio_gpu_fbdev *vfbdev = info->par;
	struct virtio_gpu_object *obj = gem_to_virtio_gpu_obj(vfbdev->vgfb.obj);
	struct ttm_tt *ttm = obj->tbo.ttm;
	unsigned long npages = vma_pages(vma);
	unsigned long addr = vma->vm_start;
	unsigned long i;
	int ret;

	if (!ttm || !ttm->pages)
		return -ENODEV;
	if (vma->vm_pgoff > ttm->num_pages ||
	    npages > ttm->num_pages - vma->vm_pgoff)
		return -EINVAL;

	vma->vm_flags |= VM_DONTEXPAND | VM_DONTDUMP;
	for (i = 0; i < npages; i++, addr += PAGE_SIZE) {
		ret = vm_insert_page(vma, addr, ttm->pages[vma->vm_pgoff + i]);
		if (ret)
			return ret;
	}
	return 0;
}

/* FBDEV_PAN_PATCH: gralloc wechselt pro Frame mit FBIOPUT_VSCREENINFO(yoffset) den Puffer.
 * Scanout auf den sichtbaren Puffer legen und dessen Inhalt zum Host schicken. Bewusst NICHT
 * drm_fb_helper_pan_display(): der macht einen atomaren Commit, der den Scanout kurz wieder
 * auf Puffer 0 (y=0) setzen wuerde (Flackern/Tearing). */
static int virtio_gpufb_pan_display(struct fb_var_screeninfo *var,
				    struct fb_info *info)
{
	struct virtio_gpu_fbdev *vfbdev = info->par;
	struct virtio_gpu_framebuffer *vgfb = &vfbdev->vgfb;
	struct virtio_gpu_device *vgdev = vgfb->base.dev->dev_private;
	struct virtio_gpu_object *obj = gem_to_virtio_gpu_obj(vgfb->obj);
	u32 xres = info->var.xres;
	u32 yres = info->var.yres;

	if (var->xoffset + xres > vgfb->base.width ||
	    var->yoffset + yres > vgfb->base.height)
		return -EINVAL;

	virtio_gpu_cmd_set_scanout(vgdev, 0, obj->hw_res_handle,
				   xres, yres, var->xoffset, var->yoffset);
	return virtio_gpu_dirty_update(vgfb, false, var->xoffset, var->yoffset,
				       xres, yres);
}

/* Der Modus ist fest; ein set_par (gralloc ruft es pro Frame) soll keinen atomaren Modeset ausloesen. */
static int virtio_gpufb_set_par(struct fb_info *info)
{
	return 0;
}

'''

if "FBDEV_MMAP_PATCH" not in s:
    marker = "static struct fb_ops virtio_gpufb_ops = {"
    if s.count(marker) != 1:
        fail("fb_ops-Definition nicht eindeutig gefunden")
    s = s.replace(marker, FUNCS.lstrip("\n") + marker)
    for old, new in ((r"\.fb_set_par\s*=\s*drm_fb_helper_set_par,[^\n]*", ".fb_set_par = virtio_gpufb_set_par,"),
                     (r"\.fb_pan_display\s*=\s*drm_fb_helper_pan_display,", ".fb_pan_display = virtio_gpufb_pan_display,\n\t.fb_mmap = virtio_gpufb_mmap,")):
        s, n = re.subn(old, new, s, count=1)
        if n != 1:
            fail("fb_ops-Eintrag nicht ersetzt: " + old)

for tag in ("DOUBLE_BUFFER_PATCH", "SMEM_LEN_PATCH", "FBDEV_MMAP_PATCH"):
    if tag not in s:
        fail(tag + " fehlt nach dem Patchen")
open(path, "w").write(s)
print("virtgpu_fb.c gepatcht: Doppelpuffer, smem_len, fb_mmap, fb_pan_display")
