namespace TerminalDeck.Core.Store;

// Names, versions and categories are catalogue facts shared with the Mac product.
// The browser owns the independently implemented extraction behavior.
public static class NativeStoreStock
{
  public static StoreEntry[] BuiltIns { get; } =
  [new("page-images", "Full-size images", "Read every image candidate the page declares, including lazy images and picture sources.", "Browser tools", "Built in", "1.0.0", "browser-tool", "Built in"),
   new("page-data", "Structured data", "Read the structured data a page publishes for other programs.", "Browser tools", "Built in", "1.0.0", "browser-tool", "Built in"),
   new("page-links", "Links and pagination", "Read page links and declared next-page destinations.", "Browser tools", "Built in", "1.0.0", "browser-tool", "Built in"),
   new("page-tables", "Tables as rows", "Read the rows and headings of HTML tables.", "Browser tools", "Built in", "1.0.0", "browser-tool", "Built in"),
   new("page-article", "Article text", "Read article text from the page's semantic content.", "Browser tools", "Built in", "1.0.0", "browser-tool", "Built in"),
   new("page-feeds", "Feeds and sitemaps", "Read feeds and sitemap links declared by the page.", "Browser tools", "Built in", "1.0.0", "browser-tool", "Built in")];
}
