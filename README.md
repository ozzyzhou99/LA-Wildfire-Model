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
5. A detailed description of the model based around the standard Overview, Design concepts, and Details (ODD) protocol can be found here.[ODD.pdf](https://github.com/ozzyzhou99/LA-Wildfire-Model/blob/main/ODD.pdf)

## Contributing

Contributions are welcome! Please open an issue or submit a pull request. 
