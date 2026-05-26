import { PageHeader } from '../components/PageHeader'

type Props = {
  title: string
  icon: string
  description: string
  phase: string
}

export function PageStub({ title, icon, description, phase }: Props) {
  return (
    <>
      <PageHeader title={title} icon={icon} description={description} />
      <div className="card p-8 text-center">
        <div className="text-text-dim text-sm uppercase tracking-widest mb-2">{phase}</div>
        <div className="text-text-muted">
          This page will be implemented in {phase}.
        </div>
      </div>
    </>
  )
}
