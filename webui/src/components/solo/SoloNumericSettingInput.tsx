import { useEffect, useRef, type InputHTMLAttributes } from 'react'

function decimal(raw: string) {
  const match = /^(-?)(\d*)(?:\.(\d*))?$/.exec(raw.trim())
  if (!match || !(match[2] || match[3]) || !Number.isFinite(Number(raw))) return null
  return { negative: match[1] === '-', whole: match[2] || '0', fraction: match[3] || '' }
}

export function stepSoloNumber(value: string, direction: 1 | -1, integer: boolean, precisionSource = value, min?: number | string, max?: number | string): string | null {
  const current = decimal(value)
  if (!current) return null
  const lower = min === undefined ? null : decimal(String(min))
  const upper = max === undefined ? null : decimal(String(max))
  const precision = Math.max(integer ? 0 : 1, current.fraction.length,
    decimal(precisionSource)?.fraction.length ?? 0, lower?.fraction.length ?? 0, upper?.fraction.length ?? 0)
  const scale = 10n ** BigInt(precision)
  const scaled = (part: NonNullable<ReturnType<typeof decimal>>) =>
    (part.negative ? -1n : 1n) * BigInt(part.whole + part.fraction.padEnd(precision, '0'))
  let next = scaled(current) + BigInt(direction) * (integer ? scale : scale / 10n)
  if (lower && next < scaled(lower)) next = scaled(lower)
  if (upper && next > scaled(upper)) next = scaled(upper)
  const digits = (next < 0n ? -next : next).toString().padStart(precision + 1, '0')
  return `${next < 0n ? '-' : ''}${precision ? `${digits.slice(0, -precision)}.${digits.slice(-precision)}` : digits}`
}

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'value' | 'onChange'> & {
  value: string
  precisionSource: string
  integer?: boolean
  onValueChange: (value: string) => void
}

export function SoloNumericSettingInput({ value, precisionSource, integer = false, onValueChange, ...props }: Props) {
  const input = useRef<HTMLInputElement>(null)
  useEffect(() => {
    const element = input.current
    if (!element) return
    const wheel = (event: WheelEvent) => {
      if (element.disabled || element.readOnly || document.activeElement !== element || event.ctrlKey || event.metaKey || !event.deltaY) return
      const next = stepSoloNumber(element.value, event.deltaY < 0 ? 1 : -1, integer, precisionSource, props.min, props.max)
      if (next === null) return
      event.preventDefault()
      onValueChange(next)
    }
    element.addEventListener('wheel', wheel, { passive: false })
    return () => element.removeEventListener('wheel', wheel)
  }, [integer, onValueChange, precisionSource, props.min, props.max])
  return <input {...props} ref={input} type="number" value={value} onChange={event => onValueChange(event.target.value)} />
}
