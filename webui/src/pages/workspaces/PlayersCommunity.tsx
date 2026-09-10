import { ChatCommandsCard } from '../gameplay/ChatCommandsCard'
import { WelcomeBackCard } from '../gameplay/WelcomeBackCard'

export function PlayersCommunity() {
  return (
    <div className="space-y-4">
      <ChatCommandsCard />
      <WelcomeBackCard />
    </div>
  )
}
