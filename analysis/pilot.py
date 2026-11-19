"""Evaluate chronological pilot observations in collateral units. Standard library only."""
import argparse
import csv
import json
import math


def evaluate(rows, operating_cost, capital_cost):
    if any(not math.isfinite(value) or value < 0 for value in (operating_cost, capital_cost)):
        raise ValueError("Costs must be finite and nonnegative")
    observations = []
    for row in rows:
        probability, loss, cap = (float(row[k]) for k in ("market_probability", "net_loss", "benefit_cap"))
        if not all(map(math.isfinite, (probability, loss, cap))) or not 0 <= probability <= 1 or loss < 0 or cap <= 0:
            raise ValueError("Invalid probability, net loss or benefit cap")
        observations.append((probability, min(loss, cap)))
    if len(observations) < 2:
        raise ValueError("At least two observations in chronological order are required")
    losses = [loss for _, loss in observations]
    market_error = baseline_error = 0.0
    failures = int(losses[0] > 0)
    for count, (forecast, loss) in enumerate(observations[1:], start=1):
        outcome = int(loss > 0)
        market_error += (forecast - outcome) ** 2
        baseline_error += (failures / count - outcome) ** 2
        failures += outcome
    mean_loss = sum(losses) / len(losses)
    return {
        "observations": len(losses),
        "mean_covered_loss": mean_loss,
        "break_even_premium_before_tail_loading": mean_loss + operating_cost + capital_cost,
        "market_brier_score": market_error / (len(losses) - 1),
        "historical_baseline_brier_score": baseline_error / (len(losses) - 1),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("observations", help="CSV with market_probability,net_loss,benefit_cap in chronological order")
    parser.add_argument("--operating-cost", type=float, required=True)
    parser.add_argument("--capital-cost", type=float, required=True)
    args = parser.parse_args()
    with open(args.observations, newline="", encoding="utf-8") as source:
        print(json.dumps(evaluate(csv.DictReader(source), args.operating_cost, args.capital_cost), indent=2))
