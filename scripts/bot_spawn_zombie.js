#!/usr/bin/env node
const mineflayer = require('mineflayer')
const { pathfinder, Movements, goals } = require('mineflayer-pathfinder')
const viewer = require('prismarine-viewer').mineflayer

const HOST = process.env.MC_HOST || '127.0.0.1'
const PORT = Number(process.env.MC_PORT || 25565)
const USERNAME = process.env.MC_USERNAME || 'CodexBot'
const VERSION = process.env.MC_VERSION || '1.21.8'
const VIEWER_PORT = Number(process.env.VIEWER_PORT || 3007)

function sleep (ms) { return new Promise(resolve => setTimeout(resolve, ms)) }

const bot = mineflayer.createBot({ host: HOST, port: PORT, username: USERNAME, auth: 'offline', version: VERSION })
bot.loadPlugin(pathfinder)

bot.once('spawn', async () => {
  try {
    viewer(bot, { port: VIEWER_PORT, firstPerson: false })
    const movements = new Movements(bot)
    bot.pathfinder.setMovements(movements)
    await sleep(4000)

    const mcData = require('minecraft-data')(bot.version)
    const Item = require('prismarine-item')(bot.version)
    const eggInfo = mcData.itemsByName.zombie_spawn_egg
    if (!eggInfo) throw new Error('zombie_spawn_egg item not found in mcData')

    await bot.creative.setInventorySlot(36, new Item(eggInfo.id, 1))
    await sleep(500)

    const egg = bot.inventory.items().find(i => i.name === 'zombie_spawn_egg')
    if (!egg) throw new Error('Failed to insert zombie spawn egg into inventory')
    await bot.equip(egg, 'hand')

    const target = bot.entity.position.floored().offset(2, 0, 2)
    await bot.pathfinder.goto(new goals.GoalNear(target.x, target.y, target.z, 1))

    const block = bot.findBlock({ maxDistance: 5, matching: b => b && b.name !== 'air' })
    if (!block) throw new Error('No usable block found to use spawn egg on')

    await bot.lookAt(block.position.offset(0.5, 1, 0.5), true)
    await sleep(500)
    await bot.activateBlock(block)

    let zombieSeen = false
    for (let i = 0; i < 40; i++) {
      const nearbyZombie = Object.values(bot.entities).find(e => e.name === 'zombie' && e.position.distanceTo(bot.entity.position) < 16)
      if (nearbyZombie) { zombieSeen = true; break }
      await sleep(500)
    }
    if (!zombieSeen) throw new Error('Zombie was not detected after using spawn egg')

    console.log('SUCCESS: Zombie spawned with zombie spawn egg.')
    console.log(`VIEWER_URL=http://127.0.0.1:${VIEWER_PORT}`)
  } catch (err) {
    console.error(`ERROR: ${err.message}`)
    process.exitCode = 1
  }
})

bot.on('kicked', reason => console.error('Bot kicked:', reason))
bot.on('error', err => console.error('Bot error:', err.message))
