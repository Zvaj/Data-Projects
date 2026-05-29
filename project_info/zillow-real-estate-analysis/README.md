# Real Estate Market Investment Analysis — Zillow

A data-driven investment analysis using Zillow datasets to evaluate where to invest $12M in the U.S. real estate market. This project analyzes home values, rental yields, and market heat indices across metropolitan areas to identify optimal markets for buy-and-rent and buy-and-flip strategies.

## Business Scenario

> *"I am a real estate investor and would like to invest $12M in the real estate market. I am particularly interested in single family homes or rental apartments. My interest is to buy properties, do upgrades, and then rent them — however I am also interested in blooming markets where I can sell properties quickly. What part of the country should I invest in to receive maximum gains?"*

## Dataset

**Zillow Research Data** — Two primary datasets merged on RegionID:

- **Home Value Dataset**: Monthly home values by region from 2000–2025 (221,000+ records), including subgroup classifications (Q1–Q4, Outlier) and national index benchmarks
- **Market Heat Index**: Regional market activity indicators showing buyer demand and market temperature

## Analysis Pipeline

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Data Load   │     │   Merge &    │     │  Statistical │     │  Visualize   │
│  & Inspect   │────▶│   Clean      │────▶│  Analysis    │────▶│  & Recommend │
│              │     │              │     │              │     │              │
│  Home Values │     │  Join on     │     │  Outlier     │     │  Trends,     │
│  Heat Index  │     │  RegionID    │     │  Detection   │     │  Comparisons │
│              │     │  Type cast   │     │  ROI Calc    │     │  Rankings    │
│              │     │  Handle NAs  │     │  Correlation │     │              │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

## Methods

- **Data merging**: Inner join of home value and heat index datasets on RegionID with type casting and validation
- **Statistical analysis**: Outlier detection, ROI calculations, trend analysis across metro markets
- **Market segmentation**: Subgroup analysis (Q1–Q4 quartiles and outlier markets) to compare entry points and growth potential
- **Visualization**: Trend plots, market comparisons, and geographic analysis using matplotlib and seaborn

## Key Findings

- Identified top-performing metro markets for rental yield and home value appreciation
- Analyzed the relationship between market heat (buyer demand) and long-term value growth
- Compared entry-point strategies across different price quartiles (Q1 = most affordable, Q4 = most expensive)
- Evaluated buy-and-rent vs. buy-and-flip potential across different market segments

## Files

| File | Description |
|------|-------------|
| `zillow_real_estate.ipynb` | Full analysis notebook with data merging, analysis, and visualizations |

## Tools & Technologies

- **Language**: Python
- **Libraries**: pandas, seaborn, matplotlib
- **Data Source**: Zillow Research (via Google Drive CSV)
- **Environment**: Google Colab

## Author

**Cheng Vang** — M.S. Data Science, University of St. Thomas (May 2026)
