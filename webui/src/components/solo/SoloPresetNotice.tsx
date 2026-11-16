import { needsSoloCustomPresetNotice } from '../../util/soloPresetGuidance'

export function SoloPresetNotice({ preset, changes }: {
  preset: string | undefined
  changes: Readonly<Record<string, string>>
}) {
  if (!needsSoloCustomPresetNotice(preset, changes)) return null
  return (
    <div role="alert" className="mb-3 rounded-md border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-warning">
      These settings require Custom difficulty. Select Custom in the game so your edited values can take effect;
      another preset may override them. DST does not change your preset.
    </div>
  )
}
