import { Icon } from '../components/Icon'
import { PageHeader } from '../components/PageHeader'
import { SUPPORTER_CREDITS } from '../data/sponsors'

export function SponsorsCredits() {
  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader
        title="DST Credits"
        icon="HeartHandshake"
        description="Recognizing the people who have contributed to Dune Server Tool and its community."
      />

      <section aria-labelledby="project-supporters-title" className="py-7 sm:py-9">
        <div className="max-w-2xl">
          <h2 id="project-supporters-title" className="text-lg font-semibold text-text">
            Supporters
          </h2>
          <p className="mt-2 max-w-[68ch] text-sm leading-6 text-text-muted">
            Thank you to the people who have shared their time, ideas, feedback, and encouragement
            with the DST project and community.
          </p>
        </div>

        <div className="mt-7 flex gap-3 border-y border-accent/40 bg-accent/10 px-4 py-4">
          <div className="flex size-10 shrink-0 items-center justify-center rounded-full bg-accent text-accent-fg">
            <Icon name="Bot" size={20} />
          </div>
          <div>
            <h3 id="duke-notes-title" className="text-lg font-bold tracking-tight text-accent-bright">
              Notes from Duke
            </h3>
            <p className="mt-1 max-w-[62ch] text-sm leading-5 text-text">
              These personal thank-you notes are written by Duke, DST&apos;s AI admin—not by Coastal. 🙂
            </p>
          </div>
        </div>

        <ul className="mt-4 divide-y divide-border" aria-label="Supporters" aria-describedby="duke-notes-title">
          {SUPPORTER_CREDITS.map(credit => (
            <li
              key={credit.displayName}
              className="flex flex-col gap-1 py-4 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between sm:gap-6"
            >
              <span className="text-lg font-semibold text-text">{credit.displayName}</span>
              <div className="text-sm leading-5 sm:w-80 sm:shrink-0 sm:text-right">
                <p className="text-text-dim">{credit.thanks}</p>
                <p className="mt-1 text-xs font-semibold text-accent-bright">— Duke</p>
              </div>
            </li>
          ))}
        </ul>
      </section>
    </div>
  )
}
