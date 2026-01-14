const fs = require("fs");
const path = require("path");

const PINTO_SUBGRAPH_URL = "https://graph.pinto.money/pintostalk";

const FIELDS_QUERY = `
  query GetFieldSowData($first: Int!, $skip: Int!) {
    fields(
      first: $first
      skip: $skip
      orderBy: sownBeans
      orderDirection: desc
    ) {
      id
      fieldId
      sownBeans
      farmer {
        id
      }
    }
  }
`;

async function fetchAllSowData() {
  const PAGE_SIZE = 1000;
  let allData = [];
  let skip = 0;
  let hasMore = true;

  console.log("Fetching sow data from Pinto subgraph");

  while (hasMore) {
    const response = await fetch(PINTO_SUBGRAPH_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query: FIELDS_QUERY,
        variables: { first: PAGE_SIZE, skip }
      })
    });

    const json = await response.json();

    for (const field of json.data.fields) {
      if (field.sownBeans == "0") {
        continue;
      }
      const address = field.farmer ? field.farmer.id : null;
      if (address) {
        allData.push([address, field.sownBeans]);
      }
    }

    console.log(`Fetched ${allData.length} records`);

    if (json.data.fields.length < PAGE_SIZE) {
      hasMore = false;
    } else {
      skip += PAGE_SIZE;
    }
  }

  const outputPath = path.join(__dirname, "outputs/sowFarmers.json");
  fs.writeFileSync(outputPath, JSON.stringify(allData, null, 2));
  console.log(`Saved ${allData.length} farmers to ${outputPath}`);

  return allData;
}

module.exports = { fetchAllSowData };

if (require.main === module) {
  fetchAllSowData()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}