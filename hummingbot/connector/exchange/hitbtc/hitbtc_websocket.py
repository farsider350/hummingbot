#!/usr/bin/env python
import asyncio
import copy
import logging
import websockets
import ujson
import hummingbot.connector.exchange.hitbtc.hitbtc_constants as constants


from typing import (
    Optional,
    AsyncIterable,
    Any,
)
from websockets.exceptions import ConnectionClosed
from hummingbot.logger import HummingbotLogger
from hummingbot.connector.exchange.hitbtc.hitbtc_auth import HitBTCAuth
from hummingbot.connector.exchange.hitbtc.hitbtc_utils import RequestId

# reusable websocket class
# ToDo: We should eventually remove this class, and instantiate web socket connection normally (see Binance for example)


class HitBTCWebsocket(RequestId):
    MESSAGE_TIMEOUT = 30.0
    PING_TIMEOUT = 10.0
    _logger: Optional[HummingbotLogger] = None

    @classmethod
    def logger(cls) -> HummingbotLogger:
        if cls._logger is None:
            cls._logger = logging.getLogger(__name__)
        return cls._logger

    def __init__(self, auth: Optional[HitBTCAuth] = None):
        self._auth: Optional[HitBTCAuth] = auth
        self._isPrivate = True if self._auth is not None else False
        self._WS_URL = constants.WSS_PRIVATE_URL if self._isPrivate else constants.WSS_PUBLIC_URL
        self._client: Optional[websockets.WebSocketClientProtocol] = None

    # connect to exchange
    async def connect(self):
        try:
            self._client = await websockets.connect(self._WS_URL)

            # if auth class was passed into websocket class
            # we need to emit authenticated requests
            if self._isPrivate:
                auth_params = self._auth.generate_auth_dict_ws(self.generate_request_id())
                await self._emit("login", auth_params)
                # TODO: wait for response
                await asyncio.sleep(1)

            return self._client
        except Exception as e:
            self.logger().error(f"Websocket error: '{str(e)}'", exc_info=True)

    # disconnect from exchange
    async def disconnect(self):
        if self._client is None:
            return

        await self._client.close()

    # receive & parse messages
    async def _messages(self) -> AsyncIterable[Any]:
        try:
            while True:
                try:
                    raw_msg_str: str = await asyncio.wait_for(self._client.recv(), timeout=self.MESSAGE_TIMEOUT)
                    raw_msg = ujson.loads(raw_msg_str)
                    # HitBTC doesn't support ping or heartbeat messages.
                    # Can handle them here if that changes - use `safe_ensure_future`.
                    yield raw_msg
                except asyncio.TimeoutError:
                    await asyncio.wait_for(self._client.ping(), timeout=self.PING_TIMEOUT)
        except asyncio.TimeoutError:
            self.logger().warning("WebSocket ping timed out. Going to reconnect...")
            return
        except ConnectionClosed:
            return
        finally:
            await self.disconnect()

    # emit messages
    async def _emit(self, method: str, data: Optional[Any] = {}) -> int:
        id = self.generate_request_id()

        payload = {
            "id": id,
            "method": method,
            "params": copy.deepcopy(data),
        }

        await self._client.send(ujson.dumps(payload))

        return id

    # request via websocket
    async def request(self, method: str, data: Optional[Any] = {}) -> int:
        return await self._emit(method, data)

    # subscribe to a method
    async def subscribe(self,
                        channel: str,
                        trading_pair: str,
                        params: Optional[Any] = {}) -> int:
        params['symbol'] = trading_pair
        return await self.request(f"subscribe{channel}", params)

    # unsubscribe to a method
    async def unsubscribe(self,
                          channel: str,
                          trading_pair: str,
                          params: Optional[Any] = {}) -> int:
        params['symbol'] = trading_pair
        return await self.request(f"unsubscribe{channel}", params)

    # listen to messages by method
    async def on_message(self) -> AsyncIterable[Any]:
        async for msg in self._messages():
            yield msg