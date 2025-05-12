# LA Wildfire Evacuation Model

## Overview

This project implements an agent-based wildfire evacuation simulation for Los Angeles using NetLogo. It integrates a Fuzzy Cognitive Map (FCM) to model emotional contagion and decision-making across different income groups. The model explores how emotional states influence evacuation patterns and contributes to understanding tail risks in emergency response.

## Prerequisites

* **NetLogo**: Version 6.4.0 or later

  * Download from [https://ccl.northwestern.edu/netlogo/](https://ccl.northwestern.edu/netlogo/)
* **R** or **Python** (optional): Required for data analysis scripts in `scripts/`. Refer to script headers for package dependencies.

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/ozzyzhou99/LA-Wildfire-Model.git
   cd LA-Wildfire-Model
   ```
2. Install NetLogo and any required R/Python packages if using the analysis scripts.

## Usage

1. Launch NetLogo and load the model from the `models/` directory (e.g., `WildfireEvacuation.nlogo`).
2. Adjust simulation parameters in the interface, such as `low-income-count`, `social-radius`, and `contagion-rate`.
3. Click **Setup** to initialize the environment, then **Go** to start the simulation.
4. Optionally, configure and run **BehaviorSpace** experiments to collect batch results.

## Results

* Simulation outputs (CSV) are saved in the `data/` folder.
* Use R or Python analysis scripts from `scripts/` to generate visualizations and statistical summaries.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request. See `docs/CONTRIBUTING.md` for guidelines.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
