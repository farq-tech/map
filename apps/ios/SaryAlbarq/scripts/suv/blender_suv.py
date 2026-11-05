"""«سَرى البارق» member car from the CC0 "Offroader SUV" (.blend) — Blender 5.x, headless.

    blender -b offroader-suv.blend -P scripts/suv/blender_suv.py -- OUT_DIR [--quick]

Writes into OUT_DIR:
  icons/CarIcon-<hex>.png     the map marker / list badge, top-rear, transparent, per member colour
  top/CarTop-<hex>.png        pure top-down variants (previews)
  layers/white.png, black.png, mask.png   the base/paint split CarIcon.paint uses for any colour
  SuvExpedition.glb           decimated glTF for the 3D mode (BODY recolourable)

The source model (CC0) is restyled: one paint (BODY, Principled with a clear-coat), black
trim/rack/flares/bumpers, dark smoked glass, emissive red tail lamps and white headlamps,
a rolled awning bag added on the rack. No logo, badge or text exists in it (checked: no
font/curve/text objects, no image textures). Studio lighting: large overhead softbox, two
side strip lights (rim), a back light, a soft fill world; shadow catcher for the contact shadow.
"""
import math
import os
import sys

import bpy
import bmesh
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(argv[0] if argv else "suv-out")
QUICK = "--quick" in argv
os.makedirs(OUT, exist_ok=True)

MEMBERS = ["E8EEF0", "D6452F", "2F6FD6", "F2B630", "2FA56A", "8A4FD1", "F07F2F", "1FB8C4", "E05A9C", "15191C"]
DARK = {"15191C"}
SCALE = 1.2  # source is ~4.1 m long; ours reads a touch larger on the map (≈4.9 m)


def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_lin(h):
    return [srgb_to_lin(int(h[i:i + 2], 16) / 255) for i in (0, 2, 4)]


# ---------------------------------------------------------------- materials

def principled(name, base, metallic=0.0, rough=0.5, coat=0.0, coat_rough=0.03, emission=None, strength=0.0, alpha=1.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    b = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(b.outputs["BSDF"], out.inputs["Surface"])
    b.inputs["Base Color"].default_value = (*base, 1.0)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Coat Roughness"].default_value = coat_rough
    if emission:
        b.inputs["Emission Color"].default_value = (*emission, 1.0)
        b.inputs["Emission Strength"].default_value = strength
    if alpha < 1:
        b.inputs["Alpha"].default_value = alpha
        m.surface_render_method = "BLENDED"
    return m


def body_color(m, lin):
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*lin, 1.0)


MAT = {
    "BODY": principled("BODY", hex_lin("E8EEF0"), 0.0, 0.32, coat=1.0, coat_rough=0.03),
    "TRIM": principled("TRIM", (0.016, 0.016, 0.017), 0.0, 0.55),
    "GLASS": principled("GLASS", (0.012, 0.014, 0.018), 0.0, 0.04, coat=1.0, coat_rough=0.02),
    "TYRE": principled("TYRE", (0.011, 0.011, 0.012), 0.0, 0.8),
    "RIM": principled("RIM", (0.42, 0.43, 0.45), 1.0, 0.3),
    "HEADLIGHT": principled("HEADLIGHT", (0.9, 0.9, 0.88), 0.0, 0.15, emission=(1.0, 0.97, 0.9), strength=4.0),
    "TAILLIGHT": principled("TAILLIGHT", (0.55, 0.02, 0.02), 0.0, 0.15, coat=1.0, emission=(1.0, 0.04, 0.03), strength=3.0),
    "INDICATOR": principled("INDICATOR", (0.8, 0.35, 0.02), 0.0, 0.2, emission=(1.0, 0.45, 0.05), strength=2.0),
}
TRIM_LIN = (0.016, 0.016, 0.017)
TRIM_DARK_BODY = (0.07, 0.075, 0.085)  # graphite trim for the near-black member

# source material → ours; "light", "light cover" depend on front/rear (decided per face)
REMAP = {
    "car paint": "BODY", "2nd car paint": "BODY",
    "plastic black": "TRIM", "pure black": "TRIM", "cloth block": "TRIM", "black metal": "TRIM",
    "black shiny metal.": "TRIM", "brake caliper": "TRIM",
    "rubber": "TYRE", "chrome": "RIM", "rough chrome": "RIM", "mirror": "GLASS",
    "windows": "GLASS", "red light": "TAILLIGHT", "red reflector": "TAILLIGHT", "orange reflector": "INDICATOR",
}


def restyle(obj):
    """Our materials on every face (lamps by end of the car: the source's nose is −Y)."""
    me = obj.data
    if me.get("sary_restyled"):
        return  # mesh data shared with an object already done
    me["sary_restyled"] = True
    names = [s.material.name if s.material else "" for s in obj.material_slots]
    order = list(MAT.keys())
    src_index = [p.material_index for p in me.polygons]  # clearing the materials resets these
    me.materials.clear()
    for k in order:
        me.materials.append(MAT[k])
    for p, si in zip(me.polygons, src_index):
        src = names[si] if si < len(names) else ""
        rear = (obj.matrix_world @ p.center).y > 0.6
        if src in ("light", "light cover"):
            dst = "TAILLIGHT" if rear else "HEADLIGHT"
        elif src == "2nd car paint" and obj.name == "Cylinder.001":
            dst = "TRIM"  # the spare's cover: black, so the tyre reads like a tyre
        else:
            dst = REMAP.get(src, "TRIM")
        p.material_index = order.index(dst)


# ---------------------------------------------------------------- scene prep

def prepare():
    sc = bpy.context.scene
    for o in list(bpy.data.objects):
        if o.type not in ("MESH", "CAMERA"):
            bpy.data.objects.remove(o)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.convert(target="MESH")  # applies Mirror + Auto Smooth (geometry nodes)
    for o in meshes:
        restyle(o)
    # Awning bag: rolled, along the rack's right side (−X here = the car's right), dark grey.
    bpy.ops.mesh.primitive_cylinder_add(vertices=20, radius=0.075, depth=1.22, location=(-0.5, 0.42, 1.52), rotation=(math.pi / 2, 0, 0))
    aw = bpy.context.active_object
    aw.name = "awning"
    aw.data.materials.append(MAT["TRIM"])
    bpy.ops.object.shade_auto_smooth(angle=math.radians(40))
    for y in (0.42 - 0.62, 0.42 + 0.62):
        bpy.ops.mesh.primitive_cylinder_add(vertices=20, radius=0.079, depth=0.03, location=(-0.5, y, 1.52), rotation=(math.pi / 2, 0, 0))
        cap = bpy.context.active_object
        cap.data.materials.append(MAT["RIM"])
    for y in (0.0, 0.85):  # brackets onto the rack
        bpy.ops.mesh.primitive_cube_add(size=1, location=(-0.46, y, 1.47), scale=(0.08, 0.04, 0.05))
        bpy.context.active_object.data.materials.append(MAT["TRIM"])
    # Uniform scale about the origin, then sit on the ground.
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    S = Matrix.Scale(SCALE, 4)
    for o in meshes:
        o.matrix_world = S @ o.matrix_world
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    zmin = min((o.matrix_world @ v.co).z for o in meshes for v in o.data.vertices)
    for o in meshes:
        o.location.z -= zmin
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)
    return meshes


def studio():
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    sc.cycles.device = "GPU"
    sc.cycles.samples = 48 if QUICK else 128
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 8
    sc.render.film_transparent = True
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    sc.view_settings.exposure = 0.0
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.image_settings.color_depth = "16"
    w = sc.world or bpy.data.worlds.new("World")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background") or w.node_tree.nodes.new("ShaderNodeBackground")
    # soft studio fill: a vertical gradient (bright above, dim floor) like an HDRI dome
    nt = w.node_tree
    for n in list(nt.nodes):
        if n.type not in ("BACKGROUND", "OUTPUT_WORLD"):
            nt.nodes.remove(n)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.35
    ramp.color_ramp.elements[0].color = (0.05, 0.05, 0.055, 1)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.75, 0.78, 0.82, 1)
    mapr = nt.nodes.new("ShaderNodeMapRange")
    mapr.inputs["From Min"].default_value = -1
    mapr.inputs["From Max"].default_value = 1
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], mapr.inputs["Value"])
    nt.links.new(mapr.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = 0.35
    out = [n for n in nt.nodes if n.type == "OUTPUT_WORLD"][0]
    nt.links.new(bg.outputs["Background"], out.inputs["Surface"])

    def area(name, loc, rot, size, size_y, power, color=(1, 1, 1)):
        l = bpy.data.lights.new(name, "AREA")
        l.shape = "RECTANGLE"
        l.size, l.size_y = size, size_y
        l.energy = power
        l.color = color
        o = bpy.data.objects.new(name, l)
        sc.collection.objects.link(o)
        o.location = loc
        o.rotation_euler = rot
        return o

    area("softbox", (0.6, -0.8, 7.0), (0.12, 0.06, 0), 5.0, 7.0, 520)
    area("rim_left", (4.5, 0.3, 2.2), (0, math.radians(68), 0), 0.6, 6.0, 110, (0.95, 0.97, 1.0))
    area("rim_right", (-4.5, 0.3, 2.2), (0, math.radians(-68), 0), 0.6, 6.0, 90, (0.95, 0.97, 1.0))
    area("back", (0, 6.0, 3.0), (math.radians(-60), 0, 0), 4.0, 1.5, 160)
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
    ground = bpy.context.active_object
    ground.name = "ground"
    ground.is_shadow_catcher = True
    return ground


def camera(mode, cam):
    sc = bpy.context.scene
    sc.camera = cam
    if mode == "rear":
        # from behind and above (the reference's angle), nose up in the frame
        el = math.radians(44)
        dist = 13.0
        tgt = Vector((0, 0.2, 0.8))
        cam.location = tgt + Vector((0, math.cos(el) * dist, math.sin(el) * dist))
        cam.rotation_euler = (tgt - cam.location).to_track_quat("-Z", "Y").to_euler()
        cam.data.type = "PERSP"
        cam.data.lens = 64
        cam.data.sensor_fit = "VERTICAL"
        sc.render.resolution_x, sc.render.resolution_y = (400, 720) if not QUICK else (200, 360)
    else:
        cam.location = (0, 0, 20)
        cam.rotation_euler = (0, 0, math.pi)  # nose (−Y) up
        cam.data.type = "ORTHO"
        cam.data.ortho_scale = 5.9
        sc.render.resolution_x, sc.render.resolution_y = (400, 720) if not QUICK else (200, 360)


def render(path):
    if "--resume" in argv and os.path.exists(path):
        return  # an earlier (interrupted) run already made it
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def set_trim(dark):
    MAT["TRIM"].node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*(TRIM_DARK_BODY if dark else TRIM_LIN), 1)
    rim = (0.7, 0.72, 0.75) if dark else (0.42, 0.43, 0.45)
    MAT["RIM"].node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*rim, 1)


def icons(cam, ground):
    for mode, folder, prefix in (("rear", "icons", "CarIcon"), ("top", "top", "CarTop")):
        camera(mode, cam)
        os.makedirs(os.path.join(OUT, folder), exist_ok=True)
        for h in (MEMBERS[:4] if QUICK else MEMBERS):
            body_color(MAT["BODY"], hex_lin(h))
            set_trim(h in DARK)
            render(os.path.join(OUT, folder, f"{prefix}-{h.lower()}.png"))
    set_trim(False)
    # base/paint split for any colour (top-rear): white paint, black paint, paint coverage
    camera("rear", cam)
    os.makedirs(os.path.join(OUT, "layers"), exist_ok=True)
    body_color(MAT["BODY"], (1, 1, 1))
    render(os.path.join(OUT, "layers", "white.png"))
    body_color(MAT["BODY"], (0, 0, 0))
    render(os.path.join(OUT, "layers", "black.png"))
    # coverage: paint as pure white emission, everything else a holdout, no shadow catcher
    ground.hide_render = True
    saved = {}
    hold = bpy.data.materials.new("HOLD")
    hold.use_nodes = True
    hold.node_tree.nodes.clear()
    ho = hold.node_tree.nodes.new("ShaderNodeHoldout")
    o2 = hold.node_tree.nodes.new("ShaderNodeOutputMaterial")
    hold.node_tree.links.new(ho.outputs[0], o2.inputs["Surface"])
    em = bpy.data.materials.new("PAINTMASK")
    em.use_nodes = True
    em.node_tree.nodes.clear()
    e = em.node_tree.nodes.new("ShaderNodeEmission")
    e.inputs["Strength"].default_value = 1.0
    o3 = em.node_tree.nodes.new("ShaderNodeOutputMaterial")
    em.node_tree.links.new(e.outputs[0], o3.inputs["Surface"])
    for o in bpy.data.objects:
        if o.type == "MESH" and o.name != "ground":
            saved[o.name] = [s.material for s in o.material_slots]
            for s in o.material_slots:
                s.material = em if s.material == MAT["BODY"] else hold
    samples = bpy.context.scene.cycles.samples
    bpy.context.scene.cycles.samples = 32
    bpy.context.scene.cycles.use_denoising = False
    render(os.path.join(OUT, "layers", "mask.png"))
    bpy.context.scene.cycles.samples = samples
    bpy.context.scene.cycles.use_denoising = True
    for o in bpy.data.objects:
        if o.name in saved:
            for s, m in zip(o.material_slots, saved[o.name]):
                s.material = m
    ground.hide_render = False


# ---------------------------------------------------------------- glTF for the 3D mode

def export_glb(budget=18000):
    for o in [o for o in bpy.data.objects if o.type != "MESH" or o.name == "ground"]:
        bpy.data.objects.remove(o)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]

    def tris(o):
        return sum(len(p.vertices) - 2 for p in o.data.polygons)

    # planar cleanup first, then a collapse ratio shared by the heavy parts
    for o in meshes:
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0008)
        bm.to_mesh(o.data)
        bm.free()
    total = sum(tris(o) for o in meshes)
    small = sum(tris(o) for o in meshes if tris(o) <= 600)
    heavy = [o for o in meshes if tris(o) > 600]
    ratio = max(0.05, min(1.0, (budget - small) / max(1, total - small)))
    for o in heavy:
        md = o.modifiers.new("dec", "DECIMATE")
        md.decimate_type = "COLLAPSE"
        md.ratio = ratio
        md.use_collapse_triangulate = True
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.modifier_apply(modifier="dec")
    # contact shadow + light rim discs for the map (same idea as before)
    sh = principled("SHADOW", (0, 0, 0), 0, 1, alpha=0.45)
    rl = principled("RIMLIGHT", (1, 1, 1), 0, 1, emission=(1, 1, 1), strength=0.5, alpha=0.5)
    bpy.ops.mesh.primitive_circle_add(vertices=40, radius=1.0, fill_type="NGON", location=(0, 0.1, 0.012))
    d = bpy.context.active_object
    d.scale = (1.15, 2.6, 1)
    d.data.materials.append(sh)
    bpy.ops.mesh.primitive_circle_add(vertices=40, radius=1.0, fill_type="NGON", location=(0, 0.1, 0.008))
    r = bpy.context.active_object
    r.scale = (1.27, 2.72, 1)
    r.data.materials.append(rl)
    bpy.ops.object.select_all(action="SELECT")
    bpy.context.view_layer.objects.active = d
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.join()
    car = bpy.context.active_object
    car.name = "sary-suv"
    bpy.ops.object.shade_auto_smooth(angle=math.radians(35))
    body_color(MAT["BODY"], hex_lin("E8EEF0"))
    print("GLB_TRIS", sum(len(p.vertices) - 2 for p in car.data.polygons))
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "SuvExpedition.glb"), export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True, export_draco_mesh_compression_enable=False,
                              export_materials="EXPORT", export_texcoords=False, export_normals=True,
                              export_vertex_color="NONE", export_cameras=False, export_lights=False)


meshes = prepare()
cam = [o for o in bpy.data.objects if o.type == "CAMERA"][0]
ground = studio()
if "--no-icons" not in argv:
    icons(cam, ground)
if "--no-glb" not in argv:
    export_glb()
print("DONE", OUT)
