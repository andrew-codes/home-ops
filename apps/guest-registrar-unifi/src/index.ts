import { logger } from "@ha/logger"
import axios from "axios"
import https from "https"
import { env } from "node:process"
import WebSocket from "ws"

const connectWebSocket = async () => {
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
    // logger.debug(JSON.stringify(event, null, 2))
    if (event.data && event.meta && event.meta.message) {
      const msgType = event.meta.message
      logger.debug("Received event:", msgType)
      switch (msgType) {
        case "sta:sync":
          logger.debug(`Client update: ${JSON.stringify(event.data, null, 2)}`)
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
  await connectWebSocket()
}

if (require.main === module) {
  run()
}

export default run
