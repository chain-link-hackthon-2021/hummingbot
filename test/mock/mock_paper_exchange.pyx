from typing import List, Tuple
import numpy as np
from decimal import Decimal

from hummingbot.connector.exchange.paper_trade.paper_trade_exchange cimport PaperTradeExchange, QuantizationParams
from hummingbot.connector.exchange.paper_trade.paper_trade_exchange import QuantizationParams
from hummingbot.connector.exchange.paper_trade.trading_pair import TradingPair
from hummingbot.core.data_type.order_book import OrderBookRow
from hummingbot.core.data_type.composite_order_book cimport CompositeOrderBook
from hummingbot.core.clock cimport Clock
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.connector.exchange.paper_trade.market_config import MarketConfig
from hummingbot.client.settings import CONNECTOR_SETTINGS, ConnectorSetting, ConnectorType, TradeFeeType
from hummingbot.core.event.events import OrderType
from hummingbot.connector.connector_base cimport ConnectorBase
from .mock_order_tracker import MockOrderTracker

s_decimal_0 = Decimal("0")

cdef class MockPaperExchange(PaperTradeExchange):

    def __init__(self, fee_percent: Decimal = Decimal("0")):
        PaperTradeExchange.__init__(self, MockOrderTracker(), MarketConfig.default_config(), MockPaperExchange)
        CONNECTOR_SETTINGS[self.name] = ConnectorSetting(self.name, ConnectorType.Exchange,
                                                         "", True, False, TradeFeeType.Percent, "",
                                                         [fee_percent, fee_percent], None, None, None, None, None)

    @property
    def name(self) -> str:
        return "MockPaperExchange"

    @property
    def display_name(self) -> str:
        return self.name

    @property
    def ready(self):
        return True

    def split_trading_pair(self, trading_pair: str) -> Tuple[str, str]:
        return trading_pair.split("-")

    def new_empty_order_book(self, trading_pair: str):
        order_book = CompositeOrderBook()
        order_book.c_add_listener(self.ORDER_BOOK_TRADE_EVENT_TAG, self._order_book_trade_listener)
        base_asset, quote_asset = self.split_trading_pair(trading_pair)
        self._trading_pairs[trading_pair] = TradingPair(trading_pair, base_asset, quote_asset)
        self.order_book_tracker._order_books[trading_pair] = order_book

    def set_balanced_order_book(self,
                                str trading_pair,
                                double mid_price,
                                double min_price,
                                double max_price,
                                double price_step_size,
                                double volume_step_size):
        self.c_set_balanced_order_book(trading_pair, mid_price, min_price, max_price, price_step_size, volume_step_size)

    cdef c_set_balanced_order_book(self,
                                   str trading_pair,
                                   double mid_price,
                                   double min_price,
                                   double max_price,
                                   double price_step_size,
                                   double volume_step_size):
        cdef:
            list bids = []
            list asks = []
            double current_price
            double current_size
            CompositeOrderBook order_book
        order_book = CompositeOrderBook()
        current_price = mid_price - price_step_size / 2
        current_size = volume_step_size
        while current_price >= min_price:
            bids.append(OrderBookRow(current_price, current_size, 1))
            current_price -= price_step_size
            current_size += volume_step_size

        current_price = mid_price + price_step_size / 2
        current_size = volume_step_size
        while current_price <= max_price:
            asks.append(OrderBookRow(current_price, current_size, 1))
            current_price += price_step_size
            current_size += volume_step_size

        order_book.apply_snapshot(bids, asks, 1)
        order_book.c_add_listener(self.ORDER_BOOK_TRADE_EVENT_TAG, self._order_book_trade_listener)
        base_asset, quote_asset = self.split_trading_pair(trading_pair)
        self._trading_pairs[trading_pair] = TradingPair(trading_pair, base_asset, quote_asset)
        self.order_book_tracker._order_books[trading_pair] = order_book

    cdef object c_get_order_price_quantum(self, str trading_pair, object price):
        cdef:
            QuantizationParams q_params
        if trading_pair in self._quantization_params:
            q_params = self._quantization_params[trading_pair]
            decimals_quantum = Decimal(f"1e-{q_params.price_decimals}")
            if price > s_decimal_0:
                precision_quantum = Decimal(f"1e{np.ceil(np.log10(price)) - q_params.price_precision}")
            else:
                precision_quantum = s_decimal_0
            return max(precision_quantum, decimals_quantum)
        else:
            return Decimal(f"1e-15")

    cdef object c_get_order_size_quantum(self, str trading_pair, object order_size):
        cdef:
            QuantizationParams q_params
        if trading_pair in self._quantization_params:
            q_params = self._quantization_params[trading_pair]
            decimals_quantum = Decimal(f"1e-{q_params.order_size_decimals}")
            if order_size > s_decimal_0:
                precision_quantum = Decimal(f"1e{np.ceil(np.log10(order_size)) - q_params.order_size_precision}")
            else:
                precision_quantum = s_decimal_0
            return max(precision_quantum, decimals_quantum)
        else:
            return Decimal(f"1e-15")

    cdef object c_quantize_order_price(self,
                                       str trading_pair,
                                       object price):
        return ConnectorBase.c_quantize_order_price(self, trading_pair, price)

    cdef object c_quantize_order_amount(self,
                                        str trading_pair,
                                        object amount,
                                        object price=s_decimal_0):
        return ConnectorBase.c_quantize_order_amount(self, trading_pair, amount, price)

    def set_quantization_param(self, QuantizationParams p):
        self._quantization_params[p.trading_pair] = p

    def supported_order_types(self) -> List[OrderType]:
        return [OrderType.LIMIT, OrderType.MARKET]

    def get_taker_order_type(self):
        return OrderType.MARKET

    cdef c_start(self, Clock clock, double timestamp):
        PaperTradeExchange.c_start(self, clock, timestamp)
        self._network_status = NetworkStatus.CONNECTED

    async def _check_network_loop(self):
        # Override the check network loop to exit immediately.
        self._network_status = NetworkStatus.CONNECTED
