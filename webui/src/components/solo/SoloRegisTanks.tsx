export function SoloRegisTanks(_props: { connectionToken: string }) {
  return <section className="card p-4 space-y-2">
    <h3 className="text-sm font-semibold">Grant Regis Tanks</h3>
    <p className="text-xs text-text-muted">Tank support is included automatically when you launch the supported Steam Solo build from DST. No separate Tank launch or enable switch is needed.</p>
    <p className="text-sm">In your Solo world, on foot in open ground: <strong>F8</strong> grants a Dart Tank; <strong>F9</strong> grants a Flamethrower Tank. One of each per launch.</p>
    <p className="text-xs text-text-muted">Known limitations: pink weapon effects, missing audio and misleading tread/PSU labels.</p>
  </section>
}
