#!/usr/bin/swift

import Foundation

enum Result<T>
{
    case success(T)
    case failure(Error)
}

struct CoreDataAttribute
{
    var name: String
    var typeName: String
    var customTypeName: String?
    var isOptional: Bool
}

class CoreDataModelParser: NSObject
{
    typealias ResultDictionary = [String: [String: CoreDataAttribute]]
    
    private let xmlParser: XMLParser
    
    private var results = ResultDictionary()
    private var completionHandler: ((Result<ResultDictionary>) -> Void)?
    
    private var currentEntityName: String?
    private var currentAttributeName: String?
    
    init?(modelURL: URL)
    {
        let modelVersionURL: URL?
        
        let metadataURL = modelURL.appendingPathComponent(".xccurrentversion")
        
        if
            let dictionary = NSDictionary(contentsOf: metadataURL) as? [String: String],
            let modelVersionFilename = dictionary["_XCCurrentVersionName"]
        {
            modelVersionURL = modelURL.appendingPathComponent(modelVersionFilename)
        }
        else
        {
            do
            {
                let contents = try FileManager.default.contentsOfDirectory(at: modelURL, includingPropertiesForKeys: nil)
                modelVersionURL = contents.first
            }
            catch
            {
                print(error)
                
                return nil
            }
        }
        
        guard let modelVersionContentsURL = modelVersionURL?.appendingPathComponent("contents"), let parser = XMLParser(contentsOf: modelVersionContentsURL) else { return nil }
        self.xmlParser = parser
        
        super.init()
        
        self.xmlParser.delegate = self
    }
    
    @discardableResult func parse(completion: ((Result<ResultDictionary>) -> Void)) -> Bool
    {
        self.completionHandler = completion
        return self.xmlParser.parse()
    }
}

extension CoreDataModelParser: XMLParserDelegate
{
    func parserDidStartDocument(_ parser: XMLParser)
    {
        self.results.removeAll()
    }
    
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error)
    {
        parser.abortParsing()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:])
    {
        switch elementName
        {
        case "entity":
            guard let name = attributeDict["name"] else { break }
            self.currentEntityName = name
            self.results[name] = [String: CoreDataAttribute]()
            
        case "attribute":
            guard let name = attributeDict["name"], let entityName = self.currentEntityName else { break }
            self.currentAttributeName = name
            
            let isOptional = attributeDict["optional"] == "YES" ? true : false
            
            let attribute = CoreDataAttribute(name: name, typeName: attributeDict["attributeType"]!, customTypeName: nil, isOptional: isOptional)
            self.results[entityName]?[name] = attribute
            
        case "entry":
            guard
                attributeDict["key"] == "customAttributeType",
                let typeName = attributeDict["value"],
                let entityName = self.currentEntityName,
                let attributeName = self.currentAttributeName
            else { break }
            
            self.results[entityName]?[attributeName]?.customTypeName = typeName
            
        default: break
        }
    }
    
    func parserDidEndDocument(_ parser: XMLParser)
    {
        if let error = parser.parserError
        {
            self.completionHandler?(.failure(error))
        }
        else
        {
            self.completionHandler?(.success(self.results))
        }
    }
}

class CoreDataFileSanitizer
{
    let modelURL: URL
    
    private var parserResults: CoreDataModelParser.ResultDictionary?
    private var parserError: Error?
    
    init?(modelURL: URL)
    {
        self.modelURL = modelURL
        
        guard let parser = CoreDataModelParser(modelURL: modelURL) else { return nil }
        
        parser.parse { (result) in
            switch result
            {
            case .success(let results): self.parserResults = results
            case .failure(let error): self.parserError = error
            }
        }
    }
    
    func sanitizeFilesInDirectory(at url: URL) throws
    {
        var contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        contents = contents.filter { $0.path.hasSuffix("+CoreDataProperties.swift") }
        
        for url in contents
        {
            try sanitizeFile(at: url)
        }
    }
    
    private func sanitizeFile(at url: URL) throws
    {
        var entityName: NSString? = nil
        Scanner(string: url.lastPathComponent).scanUpTo("+", into: &entityName)
        
        let inputString = try NSString(contentsOf: url, encoding: String.Encoding.utf8.rawValue)
        let outputString = inputString.mutableCopy() as! NSMutableString
        
        let regularExpression = try NSRegularExpression(pattern: "(?<=var )((\\w+: \\w+)(\\?)?)")
        let matches = regularExpression.matches(in: inputString as String, range: NSRange(location: 0, length: inputString.length))
        
        var offset = 0
        
        for match in matches
        {
            let matchString = (inputString.substring(with: match.range) as NSString)
            let mutableMatchString = matchString.mutableCopy() as! NSMutableString
            
            let components = mutableMatchString.components(separatedBy: ": ")
            let attributeName = components[0]
            var typeName = components[1]
            
            guard
                let results = self.parserResults,
                let entityName = entityName as? String,
                let entityDictionary = results[entityName],
                let attribute = entityDictionary[attributeName]
            else { continue }
            
            if let customTypeName = attribute.customTypeName
            {
                let range = mutableMatchString.range(of: typeName)
                
                typeName = customTypeName + (typeName.hasSuffix("?") ? "?" : "")
                mutableMatchString.replaceCharacters(in: range, with: typeName)
            }
            
            if typeName.hasSuffix("?") && !attribute.isOptional
            {
                mutableMatchString.deleteCharacters(in: NSRange(location: mutableMatchString.length - 1, length: 1))
            }
            else if !typeName.hasSuffix("?") && attribute.isOptional
            {
                mutableMatchString.append("?")
            }
            
            let range = NSRange(location: match.range.location + offset, length: match.range.length)
            outputString.replaceCharacters(in: range, with: mutableMatchString as String)
            
            offset += mutableMatchString.length - matchString.length
        }
        
        try (outputString as String).write(to: url, atomically: true, encoding: .utf8)
    }
}

let arguments = Process.arguments

guard arguments.count > 1 else { exit(1) }

let directoryURL = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let sanitizer = CoreDataFileSanitizer(modelURL: URL(fileURLWithPath: arguments[1])) else { exit(1) }

do
{
    try sanitizer.sanitizeFilesInDirectory(at: directoryURL)
}
catch
{
    print(error)
    exit(1)
}

print("Sweetened Core Data files.")
