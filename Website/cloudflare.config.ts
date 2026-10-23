export default {
    worker: {
        name: "verc",
        compatibilityDate: "2026-10-10",
        entrypoint: "worker.js",
        // The Cache API works only on custom domains, not on workers.dev.
        domains: ["verc.download"],
        workersDev: true,
    },
};
