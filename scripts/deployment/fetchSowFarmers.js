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

  console.log("fetching sow data from Pinto subgraph");

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
      allData.push({
        id: field.id,
        fieldId: field.fieldId,
        farmer: field.farmer ? field.farmer.id : null, 
        amount: field.sownBeans
      });
    }

    console.log(`  Fetched ${allData.length} records...`);

    if (json.data.fields.length < PAGE_SIZE) {
      hasMore = false;
    } else {
      skip += PAGE_SIZE;
    }
  }

  console.log(`Total farmers: ${allData.length}`);
  return allData;
}

async function main() {
  const sowData = await fetchAllSowData();
  console.log("All Farmers:");
  console.log(JSON.stringify(sowData, null, 2));
  return sowData;
}

module.exports = { fetchAllSowData };

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}