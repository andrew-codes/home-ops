import { logger } from "@ha/logger"
import axios from "axios"
import config from "dotenv"
import http from "http"
import https from "https"
import { isEmpty, throttle } from "lodash"
import { env } from "node:process"
import path from "path"
import WebSocket from "ws"

config.config({
  path: path.join(__dirname, "local.env"),
})

interface IHandleWebSocketMessage {
  (messageType: string, payload: any): void
}

const connectWebSocket = async (
  messageHandlers: Array<IHandleWebSocketMessage>,
) => {
  const { UNIFI_IP, UNIFI_USERNAME, UNIFI_PASSWORD } = env
  logger.debug(
    `Connecting to Unifi controller at ${UNIFI_IP} with username ${UNIFI_USERNAME}`,
  )
  const api = axios.create({
    baseURL: `https://${UNIFI_IP}`,
    withCredentials: true,
    httpsAgent: new https.Agent({ rejectUnauthorized: false }),
  })

  const cookieJar = {}
  const response = await api.post("/api/auth/login", {
    username: UNIFI_USERNAME,
    password: UNIFI_PASSWORD,
    rememberMe: true,
    remember: true,
  })
  const cookies = response.headers["set-cookie"]
  if (cookies) {
    cookies.forEach((cookie) => {
      const [key, value] = cookie.split(";")[0].split("=")
      cookieJar[key] = value
    })
  }
  const cookieString = Object.entries(cookieJar)
    .map(([key, value]) => `${key}=${value}`)
    .join("; ")

  const ws = new WebSocket(
    `wss://${UNIFI_IP}/proxy/network/wss/s/default/events`,
    {
      headers: {
        Cookie: cookieString,
        Upgrade: "websocket",
      },
      rejectUnauthorized: false,
    },
  )

  const connectionTimeout = setTimeout(() => {
    if (ws.readyState !== WebSocket.OPEN) {
      ws.terminate()
      logger.info("Connection attempt timed out, retrying...")
      setTimeout(connectWebSocket, 5000)
    }
  }, 10000)

  ws.on("open", () => {
    clearTimeout(connectionTimeout)
    logger.info("WebSocket connection established")

    // Set up a keepalive ping
    const pingInterval = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.ping()
      } else {
        clearInterval(pingInterval)
      }
    }, 30000)
  })

  ws.on("message", (data) => {
    const event = JSON.parse(data)
    if (event.data && event.meta && event.meta.message) {
      const msgType = event.meta.message
      switch (msgType) {
        case "sta:sync":
          for (const handler of messageHandlers) {
            try {
              handler(msgType, event.data)
            } catch (error) {
              logger.error(`Error in message handler: ${error}`)
            }
          }
          break
        default:
          break
      }
    }
  })

  ws.on("close", (code, reason) => {
    logger.debug(`WebSocket closed: ${code} - ${reason}`)
    logger.info("Connection closed, attempting to reconnect...")
    setTimeout(connectWebSocket, 5000)
  })

  ws.on("error", (error) => {
    logger.error(`WebSocket error: ${error.message}`)
    if (ws.readyState !== WebSocket.OPEN) {
      ws.terminate()
      setTimeout(connectWebSocket, 5000)
    }
  })
}

const run = async () => {
  logger.info("Starting guest-registrar-unifi application...")
  // const mqtt = await createMqtt()
  const handleClientStat = throttle(
    (type: string, payload: any) => {
      if (type !== "sta:sync") {
        return
      }
      logger.debug("Handling client stat")
      const data = payload as Array<{
        confidence?: number
        dev_cat?: number
        dev_family?: number
        mac: string
        name: string
        hostname: string
        network: string
        os_name?: number
        is_guest: boolean
      }>
      const guestDeviceTrackers = data
        .filter((client) => client.is_guest)
        .filter(
          (client) =>
            (((client.dev_cat === 1 || client.dev_family === 9) &&
              client?.confidence) ??
              0 >= 50) ||
            /.*phone.*/i.test(client.hostname),
        )
      if (!isEmpty(guestDeviceTrackers)) {
        console.debug(
          `${guestDeviceTrackers.length} guest device trackers found: ${guestDeviceTrackers.map((client) => `[${client.hostname}, ${client.mac}]`).join(", ")}`,
        )
      }
    },
    { leading: true, trailing: false, wait: 60000 },
  )
  const handlers = [handleClientStat]
  await connectWebSocket(handlers)
}

const healthServer = () => {
  const server = http.createServer((req, res) => {
    if (req.url === "/health") {
      res.writeHead(200, { "Content-Type": "text/plain" })
      res.end("OK")
    } else {
      res.writeHead(404)
      res.end()
    }
  })

  server.listen(3000, () => {
    logger.info("Health server running on port 3000")
  })
}

if (require.main === module) {
  run()
  healthServer()
}

export default run
