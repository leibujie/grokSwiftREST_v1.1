//
//  GitHubAPIManager.swift
//  grokSwiftREST
//
//  Created by Christina Moulton on 2015-11-29.
//  Copyright © 2015 Teak Mobile Inc. All rights reserved.
//

import Foundation
import Alamofire
import SwiftyJSON

class GitHubAPIManager {
  static let sharedInstance = GitHubAPIManager()
  var alamofireManager: Alamofire.Manager
  var OAuthToken: String?
  
  let clientID: String = "1234567890"
  let clientSecret: String = "abcdefghijkl"
  
  init () {
    let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
    alamofireManager = Alamofire.Manager(configuration: configuration)
  }

  func printPublicGists() -> Void {
    alamofireManager.request(GistRouter.GetPublic())
    .responseString { response in
      if let receivedString = response.result.value {
        print(receivedString)
      }
    }
  }
  
  // MARK: Basic Auth
  func printMyStarredGistsWithBasicAuth() -> Void {
    Alamofire.request(GistRouter.GetMyStarred())
    .validate()
    .responseString { response in
      if let receivedString = response.result.value {
        print(receivedString)
      }
    }
  }
  
  func doGetWithBasicAuth() -> Void {
    let username = "myUsername"
    let password = "myPassword"
    Alamofire.request(.GET, "https://httpbin.org/basic-auth/\(username)/\(password)")
      .authenticate(user: username, password: password)
      .responseString { response in
        if let receivedString = response.result.value {
          print(receivedString)
        }
      }
  }
  
  func doGetWithBasicAuthCredential() -> Void {
    let username = "myUsername"
    let password = "myPassword"
    
    let credential = NSURLCredential(user: username, password: password,
      persistence: NSURLCredentialPersistence.ForSession)
    
    Alamofire.request(.GET, "https://httpbin.org/basic-auth/\(username)/\(password)")
      .authenticate(usingCredential: credential)
      .responseString { response in
        if let receivedString = response.result.value {
        print(receivedString)
        }
      }
  }
  
  // MARK: - OAuth 2.0
  func hasOAuthToken() -> Bool {
    if let token = self.OAuthToken {
      return !token.isEmpty
    }
    return false
  }
  
  // MARK: - OAuth flow
  func URLToStartOAuth2Login() -> NSURL? {
    let authPath:String = "https://github.com/login/oauth/authorize?client_id=\(clientID)&scope=gist&state=TEST_STATE"
    guard let authURL:NSURL = NSURL(string: authPath) else {
      // TODO: handle error
      return nil
    }
    
    return authURL
  }
  
  func processOAuthStep1Response(url: NSURL) {
    let components = NSURLComponents(URL: url, resolvingAgainstBaseURL: false)
    var code:String?
    if let queryItems = components?.queryItems {
      for queryItem in queryItems {
        if (queryItem.name.lowercaseString == "code") {
          code = queryItem.value
          break
        }
      }
    }
    if let receivedCode = code {
      let getTokenPath:String = "https://github.com/login/oauth/access_token"
      let tokenParams = ["client_id": clientID, "client_secret": clientSecret,
      "code": receivedCode]
      let jsonHeader = ["Accept": "application/json"]
      Alamofire.request(.POST, getTokenPath, parameters: tokenParams, headers: jsonHeader)
        .responseString { response in
          if let error = response.result.error {
            let defaults = NSUserDefaults.standardUserDefaults()
            defaults.setBool(false, forKey: "loadingOAuthToken")
            // TODO: bubble up error
            return
          }
          print(response.result.value)
          if let receivedResults = response.result.value, jsonData = receivedResults.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false) {
            let jsonResults = JSON(data: jsonData)
            for (key, value) in jsonResults {
              switch key {
                case "access_token":
                  self.OAuthToken = value.string
                case "scope":
                  // TODO: verify scope
                  print("SET SCOPE")
                case "token_type":
                  // TODO: verify is bearer
                  print("CHECK IF BEARER")
                default:
                  print("got more than I expected from the OAuth token exchange")
                  print(key)
              }
            }
          }
          if (self.hasOAuthToken()) {
            self.printMyStarredGistsWithOAuth2()
          }
        }
    }
  }
  
  func printMyStarredGistsWithOAuth2() -> Void {
    alamofireManager.request(GistRouter.GetMyStarred())
      .responseString { response in
        guard response.result.error == nil else {
          print(response.result.error!)
          return
        }
        if let receivedString = response.result.value {
          print(receivedString)
        }
      }
  }
  
  func getGists(urlRequest: URLRequestConvertible, completionHandler: (Result<[Gist], NSError>, String?) -> Void) {
    alamofireManager.request(urlRequest)
      .validate()
      .responseArray { (response:Response<[Gist], NSError>) in
        guard response.result.error == nil,
        let gists = response.result.value else {
          print(response.result.error)
          completionHandler(response.result, nil)
          return
        }
        
        // need to figure out if this is the last page
        // check the link header, if present
        let next = self.getNextPageFromHeaders(response.response)
        completionHandler(.Success(gists), next)
    }
  }
  
  func getPublicGists(pageToLoad: String?, completionHandler: (Result<[Gist], NSError>, String?) -> Void) {
    if let urlString = pageToLoad {
      getGists(GistRouter.GetAtPath(urlString), completionHandler: completionHandler)
    } else {
      getGists(GistRouter.GetPublic(), completionHandler: completionHandler)
    }
  }
  
  func imageFromURLString(imageURLString: String, completionHandler:
    (UIImage?, NSError?) -> Void) {
    alamofireManager.request(.GET, imageURLString)
      .response { (request, response, data, error) in
      // use the generic response serializer that returns NSData
      if data == nil {
        completionHandler(nil, nil)
        return
      }
      let image = UIImage(data: data! as NSData)
      completionHandler(image, nil)
    }
  }
  
  private func getNextPageFromHeaders(response: NSHTTPURLResponse?) -> String? {
    if let linkHeader = response?.allHeaderFields["Link"] as? String {
      /* looks like:
      <https://api.github.com/user/20267/gists?page=2>; rel="next", <https://api.github.com/user/20267/gists?page=6>; rel="last"
      */
      // so split on "," then on  ";"
      let components = linkHeader.characters.split {$0 == ","}.map { String($0) }
      // now we have 2 lines like
      // '<https://api.github.com/user/20267/gists?page=2>; rel="next"'
      // So let's get the URL out of there:
      for item in components {
        // see if it's "next"
        let rangeOfNext = item.rangeOfString("rel=\"next\"", options: [])
          if rangeOfNext != nil {
          let rangeOfPaddedURL = item.rangeOfString("<(.*)>;",
          options: .RegularExpressionSearch)
          if let range = rangeOfPaddedURL {
            let nextURL = item.substringWithRange(range)
            // strip off the < and >;
            let startIndex = nextURL.startIndex.advancedBy(1)
            let endIndex = nextURL.endIndex.advancedBy(-2)
            let urlRange = startIndex..<endIndex
            return nextURL.substringWithRange(urlRange)
          }
        }
      }
    }
    return nil
  }
}