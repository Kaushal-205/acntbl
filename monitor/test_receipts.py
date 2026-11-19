import unittest
from monitor.receipts import observe


class TestMonitor(unittest.TestCase):
    def test_finalized_deadline_and_booked_benefit(self):
        calls = []
        def rpc(method, params):
            if method == "eth_chainId":
                return "0x1"
            if method == "eth_getBlockByNumber":
                return {"timestamp": "0x64", "hash": "0xabc"}
            calls.append(params)
            data = params[0]["data"]
            if data == "0x01":
                return "0x4"
            receipt_id = int(data[4:], 16)
            state = {1: 1, 2: 2, 3: 3}[receipt_id]
            words = [1, state, 2, 3, 4, 100, 5, 50, 90, 100]
            return "0x" + "".join(f"{word:064x}" for word in words)

        events = list(observe(rpc, "0x1234", 1, ["0x01", "0x02"]))
        self.assertEqual([e["evidence"]["status"] for e in events], ["expiry_callable", "credited"])
        self.assertTrue(all(params[1] == {"blockHash": "0xabc", "requireCanonical": True} for params in calls))
        self.assertEqual(events[0]["evidence"]["receipt"]["benefit"], 50)
