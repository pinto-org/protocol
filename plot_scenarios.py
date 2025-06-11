import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
from matplotlib.ticker import FuncFormatter

# Set the style
plt.style.use('seaborn-v0_8')  # Updated style name
sns.set_theme()  # Use seaborn's default theme

# Function to format y-axis values (convert from 1e6 to percentage)
def percentage_formatter(x, pos):
    return f'{x/1e6:.1f}%'

# Create figure with subplots
fig = plt.figure(figsize=(15, 14))
gs = fig.add_gridspec(3, 2, height_ratios=[1, 1, 0.3])
axes = [fig.add_subplot(gs[0, 0]), fig.add_subplot(gs[0, 1]),
        fig.add_subplot(gs[1, 0]), fig.add_subplot(gs[1, 1])]
desc_ax = fig.add_subplot(gs[2, :])

fig.suptitle('Cultivation Factor and Temperature Scenarios', fontsize=16, y=0.95)

# Scenario descriptions
scenarios = [
    ('cultivation_factor_scenario1.csv', 
     'Scenario 1: Single User Demand',
     'User sows at 100% temp limit order with maximum capacity.\n'
     'CF rises initially, then stays flat until temp returns to 100%.'),
    
    ('cultivation_factor_scenario2.csv', 
     'Scenario 2: High to Low Demand',
     'User1 sows at 100% temp with high capacity, then User2 sows at 90% with lower capacity.\n'
     'CF rises initially, then decreases to match User2\'s capacity.'),
    
    ('cultivation_factor_scenario3.csv', 
     'Scenario 3: Continuous High Demand',
     'User1 sows at high temp with max capacity, then User2 sows at lower temp.\n'
     'CF continues to rise despite lower temp due to maintained high capacity.'),
    
    ('cultivation_factor_scenario4.csv', 
     'Scenario 4: Stable Temperature',
     'Constant temperature scenario testing CF behavior.\n'
     'CF increases when soil sells out, decreases when it doesn\'t.')
]

for idx, (file, title, description) in enumerate(scenarios):
    # Read the CSV file
    df = pd.read_csv(file)
    
    # Get the subplot position
    ax = axes[idx]
    
    # Create twin axis for temperature
    ax2 = ax.twinx()
    
    # Plot cultivation factor
    line1 = ax.plot(df['iteration'], df['cultivation_factor'], 
                    'o-', label='Cultivation Factor', linewidth=2)
    
    # Plot temperature
    line2 = ax2.plot(df['iteration'], df['prev_temp'], 
                     's--', label='Temperature', linewidth=2, color='red')
    
    # Format y-axes
    ax.yaxis.set_major_formatter(FuncFormatter(percentage_formatter))
    ax2.yaxis.set_major_formatter(FuncFormatter(percentage_formatter))
    
    # Set labels and title
    ax.set_xlabel('Season')
    ax.set_ylabel('Cultivation Factor')
    ax2.set_ylabel('Temperature')
    ax.set_title(title, pad=20)
    
    # Combine legends
    lines = line1 + line2
    labels = [l.get_label() for l in lines]
    ax.legend(lines, labels, loc='upper left')
    
    # Add grid
    ax.grid(True, alpha=0.3)
    
    # Set y-axis limits with some padding
    ax.set_ylim(0, max(df['cultivation_factor']) * 1.1)
    ax2.set_ylim(min(df['prev_temp']) * 0.99, max(df['prev_temp']) * 1.01)

# Add scenario descriptions in a separate text box
desc_text = '\n\n'.join([f"{title}:\n{desc}" for _, title, desc in scenarios])
desc_ax.text(0.02, 0.5, desc_text,
             transform=desc_ax.transAxes,
             verticalalignment='center',
             bbox=dict(boxstyle='round', facecolor='white', alpha=0.8),
             fontsize=10)
desc_ax.axis('off')

# Adjust layout
plt.tight_layout()

# Save the plot
plt.savefig('cultivation_scenarios.png', dpi=300, bbox_inches='tight')
plt.close() 