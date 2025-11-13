///////////////// Pinto Facet List //////////////////
const facets = [
  "SeasonFacet", // SUN
  "SeasonGettersFacet",
  "GaugeGettersFacet",
  "GaugeFacet",
  "LiquidityWeightFacet",
  "SiloFacet", // SILO
  "ClaimFacet",
  "SiloGettersFacet",
  "WhitelistFacet",
  "ApprovalFacet",
  "BDVFacet",
  "OracleFacet",
  "ConvertFacet", // CONVERT
  "ConvertGettersFacet",
  "PipelineConvertFacet",
  "MetadataFacet", // METADATA
  "MarketplaceFacet", // MARKET
  "MarketplaceMultiFacet", // MARKETPLACE MULTI
  "FieldFacet", // FIELD
  "DepotFacet", // FARM
  "FarmFacet",
  "TokenFacet",
  "TokenSupportFacet",
  "TractorFacet",
  "PauseFacet", // DIAMOND
  "OwnershipFacet"
];

///////////////// Pinto Library List //////////////////
// A list of public libraries that need to be deployed separately.
const libraryNames = [
  "LibGauge",
  "LibIncentive",
  "LibConvert",
  "LibWellMinting",
  "LibGerminate",
  "LibPipelineConvert",
  "LibSilo",
  "LibShipping",
  "LibFlood",
  "LibTokenSilo",
  "LibEvaluate"
];

///////////////// Pinto Facet Libraries //////////////////
// A mapping of facet to public library names that will be linked to it.
const facetLibraries = {
  SeasonFacet: [
    "LibGauge",
    "LibIncentive",
    "LibWellMinting",
    "LibGerminate",
    "LibShipping",
    "LibFlood",
    "LibEvaluate"
  ],
  ConvertFacet: ["LibConvert", "LibPipelineConvert", "LibSilo", "LibTokenSilo"],
  PipelineConvertFacet: ["LibPipelineConvert", "LibSilo", "LibTokenSilo"],
  SeasonGettersFacet: ["LibWellMinting"],
  SiloFacet: ["LibSilo", "LibTokenSilo"],
  ClaimFacet: ["LibSilo", "LibTokenSilo"]
};

///////////////// Pinto linked Libraries //////////////////
// A mapping of external libraries to external libraries that need to be linked.
// Note: if a library depends on another library, the dependency will need to come
// before itself in `libraryNames`
const libraryLinks = {};

module.exports = {
  facets,
  libraryNames,
  facetLibraries,
  libraryLinks
};
