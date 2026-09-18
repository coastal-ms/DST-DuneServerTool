import { PageHeader } from '../components/PageHeader'
import { useStatus } from '../hooks/useStatus'
import { OfficialRetailServerSettingsCard } from './gameconfig/OfficialRetailServerSettingsCard'

export function ServerSettings() {
  const { status } = useStatus()
  const vmRunning = status?.vm?.running === true

  return (
    <>
      <PageHeader
        title="Server Settings"
        icon="ServerCog"
        description="Official Retail settings from the battlegroup's ServerCustomSettings.ini file."
      />
      <OfficialRetailServerSettingsCard vmRunning={vmRunning} />
    </>
  )
}
