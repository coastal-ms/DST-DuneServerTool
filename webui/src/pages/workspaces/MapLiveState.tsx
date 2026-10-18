import { LocalAtlasPreview, localAtlasPreviewUrl } from './LocalAtlasPreview'
import { AtlasLiveState } from './AtlasLiveState'

export function MapLiveState() {
  return localAtlasPreviewUrl ? <LocalAtlasPreview url={localAtlasPreviewUrl} /> : <AtlasLiveState />
}
