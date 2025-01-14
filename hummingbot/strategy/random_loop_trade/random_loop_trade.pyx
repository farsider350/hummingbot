# distutils: language=c++
from datetime import datetime
from decimal import Decimal
import time
import random
import math
from libc.stdint cimport int64_t
import logging
from typing import (
    List,
    Tuple,
    Optional,
    Dict
)
from hummingbot.core.clock cimport Clock
from hummingbot.logger import HummingbotLogger
from hummingbot.core.data_type.limit_order cimport LimitOrder
from hummingbot.core.data_type.limit_order import LimitOrder
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.connector.exchange_base import ExchangeBase
from hummingbot.connector.exchange_base cimport ExchangeBase
from hummingbot.core.event.events import (
    OrderType,
    TradeType,
    PriceType,
)
from libc.stdint cimport int64_t
from hummingbot.core.data_type.order_book cimport OrderBook
from datetime import datetime
from hummingbot.strategy.market_trading_pair_tuple import MarketTradingPairTuple
from hummingbot.strategy.strategy_base import StrategyBase

NaN = float("nan")
s_decimal_zero = Decimal(0)
ds_logger = None


cdef class RandomLoopTrade(StrategyBase):
    OPTION_LOG_NULL_ORDER_SIZE = 1 << 0
    OPTION_LOG_REMOVING_ORDER = 1 << 1
    OPTION_LOG_ADJUST_ORDER = 1 << 2
    OPTION_LOG_CREATE_ORDER = 1 << 3
    OPTION_LOG_MAKER_ORDER_FILLED = 1 << 4
    OPTION_LOG_STATUS_REPORT = 1 << 5
    OPTION_LOG_MAKER_ORDER_HEDGED = 1 << 6
    OPTION_LOG_ALL = 0x7fffffffffffffff
    CANCEL_EXPIRY_DURATION = 60.0

    @classmethod
    def logger(cls) -> HummingbotLogger:
        global ds_logger
        if ds_logger is None:
            ds_logger = logging.getLogger(__name__)
        return ds_logger

    def init_params(self,
                    market_infos: List[MarketTradingPairTuple],
                    order_type: str = "limit",
                    cancel_order_wait_time: Optional[float] = 60.0,
                    order_pricetype_random: bool = False,
                    order_pricetype_spread: bool = False,
                    order_price: Optional[Decimal] = s_decimal_zero,
                    order_price_min: Optional[Decimal] = s_decimal_zero,
                    order_price_max: Optional[Decimal] = s_decimal_zero,
                    order_spread: Optional[Decimal] = s_decimal_zero,
                    order_spread_min: Optional[Decimal] = s_decimal_zero,
                    order_spread_max: Optional[Decimal] = s_decimal_zero,
                    order_spread_pricetype: str = "mid_price",
                    is_buy: bool = True,
                    ping_pong_enabled: bool = True,
                    time_delay: float = 10.0,
                    order_amount: Decimal = Decimal("1.0"),
                    order_amount_min: Decimal = s_decimal_zero,
                    order_amount_max: Decimal = s_decimal_zero,
                    logging_options: int = OPTION_LOG_ALL,
                    status_report_interval: float = 5):

        if len(market_infos) < 1:
            raise ValueError(f"market_infos must not be empty.")

        self._market_infos = {
            (market_info.market, market_info.trading_pair): market_info
            for market_info in market_infos
        }
        self._all_markets_ready = False
        self._place_orders = True
        self._logging_options = logging_options
        self._status_report_interval = status_report_interval
        self._time_delay = time_delay
        self._time_to_cancel = {}
        self._order_type = order_type
        self._is_buy = is_buy
        self._ping_pong_enabled = ping_pong_enabled
        self._order_amount = order_amount
        self._order_amount_min = order_amount_min
        self._order_amount_max = order_amount_max
        self._start_timestamp = 0
        self._last_status_timestamp = 0
        self._last_order_timestamp = 0
        self._order_pricetype_random = order_pricetype_random
        self._order_pricetype_spread = order_pricetype_spread
        self._order_price = order_price
        self._order_price_min = order_price_min
        self._order_price_max = order_price_max
        self._order_spread = order_spread
        self._order_spread_min = order_spread_min
        self._order_spread_max = order_spread_max
        self._order_spread_pricetype = self.get_price_type(order_spread_pricetype)
        self._cancel_order_wait_time = cancel_order_wait_time

        cdef:
            set all_markets = set([market_info.market for market_info in market_infos])

        self.c_add_markets(list(all_markets))

    @property
    def order_amount(self):
        return self._order_amount

    @property
    def min_profitability(self):
        return self._min_profitability

    @property
    def active_bids(self) -> List[Tuple[ExchangeBase, LimitOrder]]:
        return self._sb_order_tracker.active_bids

    @property
    def active_asks(self) -> List[Tuple[ExchangeBase, LimitOrder]]:
        return self._sb_order_tracker.active_asks

    @property
    def active_limit_orders(self) -> List[Tuple[ExchangeBase, LimitOrder]]:
        return self._sb_order_tracker.active_limit_orders

    @property
    def in_flight_cancels(self) -> Dict[str, float]:
        return self._sb_order_tracker.in_flight_cancels

    @property
    def market_info_to_active_orders(self) -> Dict[MarketTradingPairTuple, List[LimitOrder]]:
        return self._sb_order_tracker.market_pair_to_active_orders

    @property
    def logging_options(self) -> int:
        return self._logging_options

    @logging_options.setter
    def logging_options(self, int64_t logging_options):
        self._logging_options = logging_options

    @property
    def place_orders(self):
        return self._place_orders

    def get_price(self) -> Decimal:
        price_provider = list(self._market_infos.values())[0]
        price = price_provider.get_price_by_type(self._order_spread_pricetype)
        if price.is_nan():
            price = price_provider.get_price_by_type(PriceType.MidPrice)
        return price

    def format_status(self) -> str:
        cdef:
            list lines = []
            list warning_lines = []
            dict market_info_to_active_orders = self.market_info_to_active_orders
            list active_orders = []

        for market_info in self._market_infos.values():
            active_orders = self.market_info_to_active_orders.get(market_info, [])

            warning_lines.extend(self.network_warning([market_info]))

            markets_df = self.market_status_data_frame([market_info])
            lines.extend(["", "  Markets:"] + ["    " + line for line in str(markets_df).split("\n")])

            assets_df = self.wallet_balance_data_frame([market_info])
            lines.extend(["", "  Assets:"] + ["    " + line for line in str(assets_df).split("\n")])

            # See if there're any open orders.
            if len(active_orders) > 0:
                df = LimitOrder.to_pandas(active_orders)
                df_lines = str(df).split("\n")
                lines.extend(["", "  Active orders:"] +
                             ["    " + line for line in df_lines])
            else:
                lines.extend(["", "  No active maker orders."])

            warning_lines.extend(self.balance_warning([market_info]))

        if len(warning_lines) > 0:
            lines.extend(["", "*** WARNINGS ***"] + warning_lines)

        return "\n".join(lines)

    cdef c_did_fill_order(self, object order_filled_event):
        """
        Output log for filled order.

        :param order_filled_event: Order filled event
        """
        cdef:
            str order_id = order_filled_event.order_id
            object market_info = self._sb_order_tracker.c_get_shadow_market_pair_from_order_id(order_id)
            tuple order_fill_record

        if market_info is not None:
            limit_order_record = self._sb_order_tracker.c_get_shadow_limit_order(order_id)
            order_fill_record = (limit_order_record, order_filled_event)

            if order_filled_event.trade_type is TradeType.BUY:
                if self._logging_options & self.OPTION_LOG_MAKER_ORDER_FILLED:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_info.trading_pair}) Limit buy order of "
                        f"{order_filled_event.amount} {market_info.base_asset} filled."
                    )
            else:
                if self._logging_options & self.OPTION_LOG_MAKER_ORDER_FILLED:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_info.trading_pair}) Limit sell order of "
                        f"{order_filled_event.amount} {market_info.base_asset} filled."
                    )

    cdef c_did_complete_buy_order(self, object order_completed_event):
        """
        Output log for completed buy order.

        :param order_completed_event: Order completed event
        """
        cdef:
            str order_id = order_completed_event.order_id
            object market_info = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
            LimitOrder limit_order_record

        if market_info is not None:
            limit_order_record = self._sb_order_tracker.c_get_limit_order(market_info, order_id)
            # If its not market order
            if limit_order_record is not None:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_info.trading_pair}) Limit buy order {order_id} "
                    f"({limit_order_record.quantity} {limit_order_record.base_currency} @ "
                    f"{limit_order_record.price} {limit_order_record.quote_currency}) has been completely filled."
                )
            else:
                market_order_record = self._sb_order_tracker.c_get_market_order(market_info, order_id)
                self.log_with_clock(
                    logging.INFO,
                    f"({market_info.trading_pair}) Market buy order {order_id} "
                    f"({market_order_record.amount} {market_order_record.base_asset}) has been completely filled."
                )

    cdef c_did_complete_sell_order(self, object order_completed_event):
        """
        Output log for completed sell order.

        :param order_completed_event: Order completed event
        """
        cdef:
            str order_id = order_completed_event.order_id
            object market_info = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
            LimitOrder limit_order_record

        if market_info is not None:
            limit_order_record = self._sb_order_tracker.c_get_limit_order(market_info, order_id)
            # If its not market order
            if limit_order_record is not None:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_info.trading_pair}) Limit sell order {order_id} "
                    f"({limit_order_record.quantity} {limit_order_record.base_currency} @ "
                    f"{limit_order_record.price} {limit_order_record.quote_currency}) has been completely filled."
                )
            else:
                market_order_record = self._sb_order_tracker.c_get_market_order(market_info, order_id)
                self.log_with_clock(
                    logging.INFO,
                    f"({market_info.trading_pair}) Market sell order {order_id} "
                    f"({market_order_record.amount} {market_order_record.base_asset}) has been completely filled."
                )

    cdef c_start(self, Clock clock, double timestamp):
        StrategyBase.c_start(self, clock, timestamp)
        self.logger().info(f"Waiting until markets are ready to place orders.")
        self._start_timestamp = timestamp

    cdef c_tick(self, double timestamp):
        """
        Clock tick entry point.

        For the simple trade strategy, this function simply checks for the readiness and connection status of markets, and
        then delegates the processing of each market info to c_process_market().

        :param timestamp: current tick timestamp
        """
        StrategyBase.c_tick(self, timestamp)
        cdef:
            int64_t current_tick = <int64_t>(timestamp // self._status_report_interval)
            int64_t last_tick = <int64_t>(self._last_status_timestamp // self._status_report_interval)
            bint should_report_warnings = ((current_tick > last_tick) and
                                           (self._logging_options & self.OPTION_LOG_STATUS_REPORT))
            list active_maker_orders = self.active_limit_orders

        try:
            if current_tick > last_tick:
                if not self._all_markets_ready:
                    self._all_markets_ready = all([market.ready for market in self._sb_markets])
                    if not self._all_markets_ready:
                        # Markets not ready yet. Don't do anything.
                        if should_report_warnings:
                            self.logger().warning(f"Markets are not ready. No market making trades are permitted.")
                        return

                if should_report_warnings:
                    if not all([market.network_status is NetworkStatus.CONNECTED for market in self._sb_markets]):
                        self.logger().warning(f"WARNING: Some markets are not connected or are down at the moment. Market "
                                              f"making may be dangerous when markets or networks are unstable.")

                for market_info in self._market_infos.values():
                    self.c_process_market(market_info)
        finally:
            self._last_status_timestamp = timestamp

    cdef c_place_orders(self, object market_info):
        """
        Places an order specified by the user input if the user has enough balance

        :param market_info: a market trading pair
        """
        cdef:
            ExchangeBase market = market_info.market
            object quantized_amount = s_decimal_zero
            object quantized_price
            bint random_price_enabled = self._order_pricetype_random
            bint spread_price_enabled = self._order_pricetype_spread
            object size_min = self._order_amount_min
            object size_max = self._order_amount_max
            object price_min = self._order_price_min
            object price_max = self._order_price_max
            object order_price = self._order_price
            object spread_min = self._order_spread_min
            object spread_max = self._order_spread_max
            object order_spread = self._order_spread

        # Random switcher for buy/sells it's not really ping pong because it doesn't alternate.
        if self._ping_pong_enabled:
            self._is_buy = bool(random.randint(0, 1))

        # Pick random order `order_amount` between `order_amount_min` and `order_amount_max`
        randchk_amt = (size_min is not None and
                       size_min > s_decimal_zero and
                       size_max is not None and
                       size_max > s_decimal_zero and
                       size_max > size_min)
        if randchk_amt:
            rnd_pow_amt = max((Decimal('10') ** -Decimal(str(size_min.as_tuple().exponent))),
                              (Decimal('10') ** -Decimal(str(size_max.as_tuple().exponent))))
            size_min_as_int = (size_min * rnd_pow_amt)
            size_max_as_int = (size_max * rnd_pow_amt)
            rand_amt_as_int = random.randrange(size_min_as_int, size_max_as_int)
            self._order_amount = Decimal(Decimal(str(rand_amt_as_int)) / rnd_pow_amt)

        # Calculate spread price
        if spread_price_enabled:
            reference_price = self.get_price()
            if self._is_buy:
                if random_price_enabled:
                    price_min = reference_price * (Decimal("1") - spread_max)
                    price_max = reference_price * (Decimal("1") - spread_min)
                else:
                    order_price = reference_price * (Decimal("1") - order_spread)
            else:
                if random_price_enabled:
                    price_min = reference_price * (Decimal("1") + spread_min)
                    price_max = reference_price * (Decimal("1") + spread_max)
                else:
                    order_price = reference_price * (Decimal("1") + order_spread)

        randchk_prc = (random_price_enabled and
                       price_min is not None and
                       price_min > s_decimal_zero and
                       price_max is not None and
                       price_max > s_decimal_zero and
                       price_max > price_min)
        # Pick random `order_price` between min and max values
        if randchk_prc:
            prc_rnd_pow = max((Decimal('10') ** -Decimal(str(price_min.as_tuple().exponent))),
                              (Decimal('10') ** -Decimal(str(price_max.as_tuple().exponent))))
            prc_min_as_int = (price_min * prc_rnd_pow)
            prc_max_as_int = (price_max * prc_rnd_pow)
            rand_prc = random.randrange(prc_min_as_int, prc_max_as_int)
            order_price = Decimal(Decimal(str(rand_prc)) / prc_rnd_pow)

        # Set Amount
        quantized_amount = market.c_quantize_order_amount(market_info.trading_pair, self._order_amount)

        self.logger().info(f"Checking to see if the user has enough balance to place orders")
        if self.c_has_enough_balance(market_info):

            if self._order_type == "market":
                if self._is_buy:
                    order_id = self.c_buy_with_specific_market(market_info,
                                                               amount=quantized_amount)

                    self.logger().info(f"Market buy order of {quantized_amount} has been executed.")
                else:
                    order_id = self.c_sell_with_specific_market(market_info,
                                                                amount=quantized_amount)
                    self.logger().info(f"Market sell order of {quantized_amount} has been executed.")
            else:
                quantized_price = market.c_quantize_order_price(market_info.trading_pair, order_price)
                if self._is_buy:
                    order_id = self.c_buy_with_specific_market(market_info,
                                                               amount=quantized_amount,
                                                               order_type=OrderType.LIMIT,
                                                               price=quantized_price)
                    self.logger().info(f"Limit buy order of {quantized_amount} has been placed @ {quantized_price}")

                else:
                    order_id = self.c_sell_with_specific_market(market_info,
                                                                amount=quantized_amount,
                                                                order_type=OrderType.LIMIT,
                                                                price=quantized_price)
                    self.logger().info(f"Limit sell order of {quantized_amount} has been placed @ {quantized_price}")

                self._time_to_cancel[order_id] = self._current_timestamp + self._cancel_order_wait_time
        else:
            self.logger().info(f"Not enough balance to run the strategy. Please check balances and try again.")

    cdef c_has_enough_balance(self, object market_info):
        """
        Checks to make sure the user has the sufficient balance in order to place the specified order

        :param market_info: a market trading pair
        :return: True if user has enough balance, False if not
        """
        cdef:
            ExchangeBase market = market_info.market
            object base_asset_balance = market.c_get_available_balance(market_info.base_asset)
            object quote_asset_balance = market.c_get_available_balance(market_info.quote_asset)
            OrderBook order_book = market_info.order_book
            object price = market_info.get_price_for_volume(True, self._order_amount).result_price
        if math.isnan(price):
            price = self.get_price()
        return quote_asset_balance >= self._order_amount * price if self._is_buy else base_asset_balance >= self._order_amount

    cdef c_process_market(self, object market_info):
        """
        Checks if enough time has elapsed to place orders and if so, calls c_place_orders() and cancels orders if they
        are older than self._cancel_order_wait_time.

        :param market_info: a market trading pair
        """
        cdef:
            ExchangeBase maker_market = market_info.market
            set cancel_order_ids = set()
            int64_t current_tick = <int64_t>(self._current_timestamp // self._time_delay)
            int64_t last_tick = <int64_t>(self._last_order_timestamp // self._time_delay)

        # if self._place_orders and order interval is ready, place orders.
        if self._place_orders and current_tick > last_tick:
            self.logger().info("Trying to place orders on Random Loop interval now")
            self.c_place_orders(market_info)
            # Set last order timestamp here for loop mode
            self._last_order_timestamp = int(time.time())

        active_orders = self.market_info_to_active_orders.get(market_info, [])

        if len(active_orders) > 0:
            for active_order in active_orders:
                if self._current_timestamp >= self._time_to_cancel[active_order.client_order_id]:
                    cancel_order_ids.add(active_order.client_order_id)

        if len(cancel_order_ids) > 0:

            for order in cancel_order_ids:
                self.c_cancel_order(market_info, order)

    def get_price_type(self, price_type_str: str) -> PriceType:
        if price_type_str == "mid_price":
            return PriceType.MidPrice
        elif price_type_str == "best_bid":
            return PriceType.BestBid
        elif price_type_str == "best_ask":
            return PriceType.BestAsk
        elif price_type_str == "last_price":
            return PriceType.LastTrade
        else:
            raise ValueError(f"Unrecognized price type string {price_type_str}.")
