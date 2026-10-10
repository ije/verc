import { cp, lstat, mkdir, readdir, rename, rm } from "node:fs/promises";
import { basename, join, resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
process.chdir(root);
const debug = process.argv.includes("--debug");
const config = debug ? "debug" : "release";
const swift = ["swift", "build", "--disable-sandbox", "--cache-path", ".build/cache", "-c", config, "--arch", "arm64"];
const app = join(root, ".build/Verc.app");
const output = join(root, "dist/Verc.app");
const env = { ...process.env, CLANG_MODULE_CACHE_PATH: join(root, ".build/ModuleCache"), SWIFTPM_MODULECACHE_OVERRIDE: join(root, ".build/ModuleCache") };
const runtime = process.env.VERC_VLC_PATH ?? "/Applications/VLC.app/Contents/MacOS";
const profile = await Bun.file(join(root, "scripts/vlc-plugins.json")).json();
const plugins = Object.values(profile).flat();

if (process.platform !== "darwin" || process.arch !== "arm64") throw new Error("Build Verc on an Apple silicon Mac.");
if (new Set(plugins).size !== plugins.length) throw new Error("Duplicate VLC plugin in the build profile.");
for (const name of plugins) {
  if (!await Bun.file(join(runtime, `plugins/lib${name}_plugin.dylib`)).exists()) throw new Error(`Required VLC plugin is missing: ${name}`);
}
const build = Bun.spawn([...swift, ...(debug ? [] : ["-Xswiftc", "-Osize"])], { env, stdout: "inherit", stderr: "inherit" });
if (await build.exited !== 0) throw new Error("Swift build failed.");
await rm(app, { recursive: true, force: true });
await mkdir(join(app, "Contents/MacOS"), { recursive: true });
await mkdir(join(app, "Contents/Resources"), { recursive: true });
const location = Bun.spawnSync([...swift, "--show-bin-path"], { env, stdout: "pipe", stderr: "inherit" });
if (location.exitCode !== 0) throw new Error("Cannot locate the compiled app.");
await cp(join(location.stdout.toString().trim(), "Verc"), join(app, "Contents/MacOS/Verc"));
await cp("Resources/Info.plist", join(app, "Contents/Info.plist"));
for (const file of ["Resources/Verc.icns", "Resources/LineMD-LICENSE.txt", "LICENSE", "NOTICE"]) {
  await cp(file, join(app, "Contents/Resources", basename(file)));
}
const destination = join(app, "Contents/Frameworks/VLC");
await mkdir(join(destination, "plugins"), { recursive: true });
await cp(join(runtime, "lib"), join(destination, "lib"), { recursive: true, verbatimSymlinks: true });
for (const name of plugins) {
  const file = `lib${name}_plugin.dylib`;
  await cp(join(runtime, "plugins", file), join(destination, "plugins", file));
}
const subtitlePlugin = Bun.spawnSync([
  "clang", "-dynamiclib", "-arch", "arm64", "-mmacosx-version-min=26.0", "-Os",
  "-D__PLUGIN__", "-DMODULE_NAME=vercsub", '-DMODULE_STRING="vercsub"',
  "-I", "Vendor/VLC/include", "-I", "Sources/CVLC/include", "-undefined", "dynamic_lookup",
  "-install_name", "@rpath/libvercsub_plugin.dylib",
  "Plugins/Subtitle.c", "-o", join(destination, "plugins/libvercsub_plugin.dylib")
], { stderr: "inherit" });
if (subtitlePlugin.exitCode !== 0) throw new Error("Cannot build the subtitle layout plugin.");
for (const file of await readdir(destination, { recursive: true })) {
  const path = join(destination, file);
  if (!file.endsWith(".dylib") || !(await lstat(path)).isFile()) continue;
  const architecture = Bun.spawnSync(["lipo", "-archs", path], { stdout: "pipe", stderr: "pipe" });
  const archs = architecture.stdout.toString().trim().split(/\s+/);
  if (architecture.exitCode !== 0 || !archs.includes("arm64")) throw new Error(`ARM64 is missing: ${file}`);
  if (archs.length > 1) {
    const result = Bun.spawnSync(["lipo", path, "-thin", "arm64", "-output", path], { stderr: "inherit" });
    if (result.exitCode !== 0) throw new Error(`Cannot remove unused architectures: ${file}`);
  }
  const dependencies = Bun.spawnSync(["otool", "-L", path], { stdout: "pipe", stderr: "inherit" });
  if (dependencies.exitCode !== 0) throw new Error(`Cannot inspect dependencies: ${file}`);
  for (const line of dependencies.stdout.toString().trim().split("\n").slice(2)) {
    const dependency = line.trim().split(" (compatibility version")[0];
    if (dependency.startsWith("/System/Library/") || dependency.startsWith("/usr/lib/")) continue;
    if (dependency.startsWith("@rpath/") && await Bun.file(join(destination, "lib", dependency.slice(7))).exists()) continue;
    throw new Error(`Unbundled dependency in ${file}: ${dependency}`);
  }
}
if (!debug) {
  const result = Bun.spawnSync(["strip", "-S", "-x", join(app, "Contents/MacOS/Verc")], { stderr: "inherit" });
  if (result.exitCode !== 0) throw new Error("Cannot strip the release executable.");
}
await cp(join(root, "scripts/vlc-plugins.json"), join(app, "Contents/Resources/VLC-plugins.json"));
await Bun.write(join(app, "Contents/Resources/VLC-runtime.txt"), `Selected playback runtime from ${runtime}\n${plugins.length} VLC plugins plus Verc's subtitle layout plugin. No VLC desktop UI, extensions, translations, capture, casting, or dedicated encoder modules.\nInclude corresponding VLC and dependency sources when you distribute this bundle. See NOTICE.\n`);
for (const cmd of [["codesign", "--force", "--deep", "--sign", "-", app], ["codesign", "--verify", "--deep", "--strict", app]]) {
  const result = Bun.spawnSync(cmd, { stdout: "inherit", stderr: "inherit" });
  if (result.exitCode !== 0) throw new Error("App signature verification failed.");
}
let bytes = 0;
for (const file of await readdir(app, { recursive: true })) {
  const info = await lstat(join(app, file));
  if (info.isFile()) bytes += info.size;
}
if (!debug && bytes > 50 * 1048576) throw new Error("The release exceeds 50 MiB. Review the playback plugin profile before distribution.");
await mkdir(join(root, "dist"), { recursive: true });
await rm(output, { recursive: true, force: true });
await rename(app, output);
console.log(`\n${output}\nStandalone · ARM64 · macOS 26+ · ${(bytes / 1048576).toFixed(2)} MiB total · ${plugins.length + 1} playback plugins`);
