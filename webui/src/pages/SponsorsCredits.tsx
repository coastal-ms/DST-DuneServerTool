import { Icon } from '../components/Icon'
import { PageHeader } from '../components/PageHeader'
import { SPONSORS } from '../data/sponsors'

export function SponsorsCredits() {
  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader
        title="Sponsors & Credits"
        icon="HeartHandshake"
        description="Recognizing the people who help sustain Dune Server Tool."
      />

      <section aria-labelledby="discord-sponsors-title" className="border-y border-border py-7 sm:py-9">
        <div className="max-w-2xl">
          <h2 id="discord-sponsors-title" className="text-lg font-semibold text-text">
            Discord Sponsors
          </h2>
          <p className="mt-2 max-w-[68ch] text-sm leading-6 text-text-muted">
            Their support helps sustain DST development and the time spent helping the community.
            Thank you for standing behind the project.
          </p>
        </div>

        <ul className="mt-7 divide-y divide-border" aria-label="Discord Sponsors">
          {SPONSORS.map(sponsor => (
            <li key={sponsor.name} className="flex items-center justify-between gap-4 py-4 first:pt-0 last:pb-0">
              <span className="text-lg font-semibold text-text">{sponsor.name}</span>
              <span className="text-xs font-medium uppercase tracking-wider text-text-dim">
                {sponsor.recognition}
              </span>
            </li>
          ))}
        </ul>
      </section>

      <section aria-labelledby="support-dst-title" className="py-7 sm:py-9">
        <h2 id="support-dst-title" className="text-base font-semibold text-text">Support DST</h2>
        <p className="mt-2 max-w-[68ch] text-sm leading-6 text-text-muted">
          If DST is useful to you and you would like to support its continued development,
          you can do so through Buy Me a Coffee.
        </p>
        <a
          href="https://buymeacoffee.com/coastal_dst"
          target="_blank"
          rel="noopener noreferrer"
          className="btn-secondary mt-4 min-h-11"
        >
          <Icon name="Coffee" size={16} />
          Buy Me a Coffee
          <Icon name="ExternalLink" size={13} className="text-text-dim" />
        </a>
      </section>
    </div>
  )
}
