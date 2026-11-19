import hashlib
import unittest

from analysis.pilot import evaluate
from monitor.claim_proof import build_proof


class TestTools(unittest.TestCase):
    def test_odd_width_proofs_rebuild_root_for_every_position(self):
        def digest(value):
            return hashlib.sha256(value).digest()
        for size in range(1, 18):
            leaves = [digest(bytes([i])) for i in range(size)]
            for index, leaf in enumerate(leaves):
                root, proof = build_proof(leaves, index, digest)
                for sibling in proof:
                    leaf = digest(b"".join(sorted([leaf, sibling])))
                self.assertEqual(leaf, root)

    def test_pricing_uses_capped_loss_and_earlier_observations(self):
        rows = [dict(market_probability=0, net_loss=0, benefit_cap=25),
                dict(market_probability=.5, net_loss=100, benefit_cap=25)]
        result = evaluate(rows, 1, 2)
        self.assertEqual(result["break_even_premium_before_tail_loading"], 15.5)
        self.assertEqual(result["market_brier_score"], .25)
        self.assertEqual(result["historical_baseline_brier_score"], 1)
