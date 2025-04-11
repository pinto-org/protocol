const fs = require("fs");
// this script was generated with LLM assistance.

function generateHtml(cases) {
  let html = `
<!DOCTYPE html>
<html>
<head>
    <title>Beanstalk Weather Cases</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
        }
        .l2sr-section {
            margin-bottom: 40px;
            max-width: 1200px;
            margin-left: auto;
            margin-right: auto;
        }
        .case-table {
            border-collapse: collapse;
            width: 100%;
            margin-bottom: 20px;
            table-layout: fixed;
        }
        .case-table th, .case-table td {
            border: 1px solid #ddd;
            padding: 8px;
            text-align: left;
            position: relative;
            font-size: 18px;
            overflow: visible;
            text-overflow: ellipsis;
        }
        .case-table th {
            background-color: #f4f4f4;
        }
        .highlighted {
            background-color: #ffeb3b;
            transition: background-color 0.3s;
        }
        .search-container {
            margin-bottom: 20px;
            text-align: center;
        }
        input {
            padding: 8px;
            font-size: 16px;
        }
        .tooltip {
            visibility: hidden;
            background-color: black;
            color: white;
            text-align: center;
            padding: 5px 10px;
            border-radius: 6px;
            position: absolute;
            z-index: 1;
            bottom: 125%;
            left: 50%;
            transform: translateX(-50%);
            white-space: nowrap;
            pointer-events: none;
            opacity: 0;
            transition: opacity 0.2s, visibility 0.2s;
        }
        td:hover .tooltip {
            visibility: visible;
            opacity: 1;
        }
    </style>
</head>
<body>
    <h1>Beanstalk Weather Cases</h1>
    <div class="search-container">
        <label for="caseIdInput">Enter Case ID (0-143): </label>
        <input type="number" id="caseIdInput" min="0" max="143" />
    </div>
    <div id="cases-container">
`;

  const levels = [
    "Excessively Low L2SR",
    "Reasonably Low L2SR",
    "Reasonably High L2SR",
    "Excessively High L2SR"
  ];

  levels.forEach((level, levelIndex) => {
    html += `
    <div class="l2sr-section" data-l2sr-level="${levelIndex}">
        <h2>${level}</h2>
        <table class="case-table">
            <thead>
                <tr>
                    <th>Price</th>
                    <th>Demand</th>
                    <th>Excessively Low Debt</th>
                    <th>Reasonably Low Debt</th>
                    <th>Reasonably High Debt</th>
                    <th>Excessively High Debt</th>
                </tr>
            </thead>
            <tbody>
    `;

    const prices = ["P > Q", "P > 1", "P < 1"];
    const demands = ["Increasing", "Steady", "Decreasing"];

    prices.forEach((price) => {
      demands.forEach((demand, i) => {
        html += '<tr data-price="' + price + '" data-demand="' + demand + '">';

        if (i === 0) {
          html += `<td rowspan="3">${price}</td>`;
        }

        html += `<td>${demand}</td>`;

        for (let debt = 0; debt < 4; debt++) {
          let priceOffset;
          switch (price) {
            case "P > Q":
              priceOffset = 2;
              break;
            case "P > 1":
              priceOffset = 1;
              break;
            case "P < 1":
              priceOffset = 0;
              break;
          }

          let demandOffset;
          switch (demand) {
            case "Increasing":
              demandOffset = 2;
              break;
            case "Steady":
              demandOffset = 1;
              break;
            case "Decreasing":
              demandOffset = 0;
              break;
          }

          const caseIndex = levelIndex * 36 + debt * 9 + priceOffset * 3 + demandOffset;
          console.log(
            `Level: ${level}, Price: ${price}, Demand: ${demand}, Debt: ${debt}, Index: ${caseIndex}`
          );

          const caseData = cases[caseIndex];

          if (!caseData) {
            html += "<td>N/A</td>";
            continue;
          }

          const changes = parseCaseName(caseData);
          html += `
            <td data-case-id="${caseIndex}">
                <span class="tooltip">Case ID: ${caseIndex}</span>
                ${changes.temp}, ${changes.ratio}
            </td>
          `;
        }

        html += "</tr>";
      });
    });

    html += `
            </tbody>
        </table>
    </div>
    `;
  });

  html += `
    </div>
    <script>
        document.getElementById('caseIdInput').addEventListener('input', function(e) {
            // Remove previous highlight
            const previousHighlight = document.querySelector('.highlighted');
            if (previousHighlight) {
                previousHighlight.classList.remove('highlighted');
            }

            const caseId = parseInt(e.target.value);
            if (isNaN(caseId) || caseId < 0 || caseId > 143) return;

            // Find and highlight the cell
            const cell = document.querySelector(\`td[data-case-id="\${caseId}"]\`);
            if (cell) {
                cell.classList.add('highlighted');
                // Scroll cell into view
                cell.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
        });
    </script>
</body>
</html>
  `;

  return html;
}

function parseLibCases() {
  const path = require("path");
  const content = fs.readFileSync(
    path.join(__dirname, "..", "contracts", "libraries", "LibCases.sol"),
    "utf8"
  );

  const casesMatch = content.match(/s\.sys\.casesV2 = \[([\s\S]*?)\];/);
  if (!casesMatch) {
    console.error("Could not find cases array in LibCases.sol");
    return null;
  }

  const cases = [];
  const lines = casesMatch[1].split("\n");

  lines.forEach((line) => {
    if (!line.trim() || line.trim().startsWith("//")) return;

    const casesInLine = line
      .split(",")
      .map((part) => part.trim())
      .filter(Boolean);

    casesInLine.forEach((caseText) => {
      const match = caseText.match(/bytes32\((.*?)\)/) || [null, caseText];
      if (match && match[1]) {
        const caseName = match[1].split("//")[0].trim();
        if (caseName && !caseName.includes("///")) {
          cases.push(caseName);
        }
      }
    });
  });

  return cases;
}

function parseCaseName(caseName) {
  if (!caseName) {
    return { temp: "ERR", ratio: "ERR" };
  }

  const temp = caseName.match(/T_(PLUS|MINUS)_(\d+)/);
  const ratio = caseName.match(/L_(PLUS|MINUS)_(\w+)/);

  function convertRatioToDecimal(word) {
    switch (word) {
      case "FIFTY":
        return "0.5";
      case "ONE":
        return "0.01";
      case "TWO":
        return "0.02";
      default:
        return word;
    }
  }

  return {
    temp: temp ? `${temp[1] === "PLUS" ? "+" : "-"}${temp[2]}%` : "N/A",
    ratio: ratio ? `${ratio[1] === "PLUS" ? "+" : "-"}${convertRatioToDecimal(ratio[2])}` : "N/A"
  };
}

// Generate and save the HTML
const cases = parseLibCases();
if (cases) {
  const html = generateHtml(cases);
  const path = require("path");
  const outputPath = path.join(__dirname, "html", "weather_cases.html");

  // Create the html directory if it doesn't exist
  const outputDir = path.dirname(outputPath);
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  fs.writeFileSync(outputPath, html);
  console.log(`Successfully wrote ${outputPath}`);
} else {
  console.error("Failed to generate HTML");
}
