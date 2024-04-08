//
//  FeedbinAPICaller.swift
//  Account
//
//  Created by Maurice Parker on 5/2/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

// Feedbin currently has a maximum of 250 requests per second.  If you begin to receive
// HTTP Response Codes of 403, you have exceeded this limit.  Wait 5 minutes and your
// IP address will become unblocked and you can use the service again.

import Foundation
import Web
import Secrets
import Feedbin

enum CreateSubscriptionResult {
	case created(FeedbinSubscription)
	case multipleChoice([FeedbinSubscriptionChoice])
	case alreadySubscribed
	case notFound
}

final class FeedbinAPICaller: NSObject {

	struct ConditionalGetKeys {
		static let subscriptions = "subscriptions"
		static let tags = "tags"
		static let taggings = "taggings"
		static let unreadEntries = "unreadEntries"
		static let starredEntries = "starredEntries"
	}
	
	private let feedbinBaseURL = URL(string: "https://api.feedbin.com/v2/")!
	private var transport: Transport!
	private var suspended = false
	private var lastBackdateStartTime: Date?
	
	var credentials: Credentials?
	weak var accountMetadata: AccountMetadata?

	init(transport: Transport) {
		super.init()
		self.transport = transport
	}
	
	/// Cancels all pending requests rejects any that come in later
	func suspend() {
		transport.cancelAll()
		suspended = true
	}
	
	func resume() {
		suspended = false
	}
	
	func validateCredentials() async throws -> Credentials? {

		let callURL = feedbinBaseURL.appendingPathComponent("authentication.json")
		let request = URLRequest(url: callURL, credentials: credentials)

		do {
			try await transport.send(request: request)
			return credentials
		} catch {
			if case TransportError.httpError(let status) = error, status == 401 {
				return nil
			}
			throw error
		}
	}

	func importOPML(opmlData: Data) async throws -> FeedbinImportResult {

		let callURL = feedbinBaseURL.appendingPathComponent("imports.json")
		var request = URLRequest(url: callURL, credentials: credentials)
		request.addValue("text/xml; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)

		let (_, data) = try await transport.send(request: request, method: HTTPMethod.post, payload: opmlData)
		guard let data else {
			throw TransportError.noData
		}

		let parsingTask = Task.detached { () throws -> FeedbinImportResult in
			try JSONDecoder().decode(FeedbinImportResult.self, from: data)
		}

		let importResult = try await parsingTask.value
		return importResult
	}

	func retrieveOPMLImportResult(importID: Int) async throws -> FeedbinImportResult? {

		let callURL = feedbinBaseURL.appendingPathComponent("imports/\(importID).json")
		let request = URLRequest(url: callURL, credentials: credentials)

		let (_, importResult) = try await transport.send(request: request, resultType: FeedbinImportResult.self)
		return importResult
	}

	func retrieveTags() async throws -> [FeedbinTag]? {

		if suspended { throw TransportError.suspended }

		let callURL = feedbinBaseURL.appendingPathComponent("tags.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.tags]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)

		let (response, tags) = try await transport.send(request: request, resultType: [FeedbinTag].self)

		storeConditionalGet(key: ConditionalGetKeys.tags, headers: response.allHeaderFields)

		return tags
	}

	func renameTag(oldName: String, newName: String, completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("tags.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinRenameTag(oldName: oldName, newName: newName)
		
		transport.send(request: request, method: HTTPMethod.post, payload: payload) { result in
			
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func retrieveSubscriptions() async throws -> [FeedbinSubscription]? {

		var callComponents = URLComponents(url: feedbinBaseURL.appendingPathComponent("subscriptions.json"), resolvingAgainstBaseURL: false)!
		callComponents.queryItems = [URLQueryItem(name: "mode", value: "extended")]

		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.subscriptions]
		let request = URLRequest(url: callComponents.url!, credentials: credentials, conditionalGet: conditionalGet)

		let (response, subscriptions) = try await transport.send(request: request, resultType: [FeedbinSubscription].self)

		storeConditionalGet(key: ConditionalGetKeys.subscriptions, headers: response.allHeaderFields)

		return subscriptions
	}
	
	func createSubscription(url: String, completion: @escaping (Result<CreateSubscriptionResult, Error>) -> Void) {
		
		var callComponents = URLComponents(url: feedbinBaseURL.appendingPathComponent("subscriptions.json"), resolvingAgainstBaseURL: false)!
		callComponents.queryItems = [URLQueryItem(name: "mode", value: "extended")]

		var request = URLRequest(url: callComponents.url!, credentials: credentials)
		request.addValue("application/json; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)
		
		let payload: Data
		do {
			payload = try JSONEncoder().encode(FeedbinCreateSubscription(feedURL: url))
		} catch {
			completion(.failure(error))
			return
		}
		
		transport.send(request: request, method: HTTPMethod.post, payload: payload) { result in
			
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}
			
			switch result {
			case .success(let (response, data)):
				
				switch response.forcedStatusCode {
				case 201:
					guard let subData = data else {
						completion(.failure(TransportError.noData))
						break
					}
					do {
						let subscription = try JSONDecoder().decode(FeedbinSubscription.self, from: subData)
						completion(.success(.created(subscription)))
					} catch {
						completion(.failure(error))
					}
				case 300:
					guard let subData = data else {
						completion(.failure(TransportError.noData))
						break
					}
					do {
						let subscriptions = try JSONDecoder().decode([FeedbinSubscriptionChoice].self, from: subData)
						completion(.success(.multipleChoice(subscriptions)))
					} catch {
						completion(.failure(error))
					}
				case 302:
					completion(.success(.alreadySubscribed))
				default:
					completion(.failure(TransportError.httpError(status: response.forcedStatusCode)))
				}
				
			case .failure(let error):
				
				switch error {
				case TransportError.httpError(let status):
					switch status {
					case 401:
						// I don't know why we get 401's here.  This looks like a Feedbin bug, but it only happens
						// when you are already subscribed to the feed.
						completion(.success(.alreadySubscribed))
					case 404:
						completion(.success(.notFound))
					default:
						completion(.failure(error))
					}
				default:
					completion(.failure(error))
				}
				
			}
			
		}
		
	}
	
	func renameSubscription(subscriptionID: String, newName: String, completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("subscriptions/\(subscriptionID)/update.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinUpdateSubscription(title: newName)
		
		transport.send(request: request, method: HTTPMethod.post, payload: payload) { result in
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}
			
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func deleteSubscription(subscriptionID: String) async throws {

		if suspended { throw TransportError.suspended }

		let callURL = feedbinBaseURL.appendingPathComponent("subscriptions/\(subscriptionID).json")
		let request = URLRequest(url: callURL, credentials: credentials)
		
		try await transport.send(request: request, method: HTTPMethod.delete)
	}
	
	func retrieveTaggings() async throws -> [FeedbinTagging]? {

		if suspended { throw TransportError.suspended }

		let callURL = feedbinBaseURL.appendingPathComponent("taggings.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.taggings]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)

		let (response, taggings) = try await transport.send(request: request, resultType: [FeedbinTagging].self)

		storeConditionalGet(key: ConditionalGetKeys.taggings, headers: response.allHeaderFields)

		return taggings
	}

	func createTagging(feedID: Int, name: String, completion: @escaping (Result<Int, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("taggings.json")
		var request = URLRequest(url: callURL, credentials: credentials)
		request.addValue("application/json; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)

		let payload: Data
		do {
			payload = try JSONEncoder().encode(FeedbinCreateTagging(feedID: feedID, name: name))
		} catch {
			completion(.failure(error))
			return
		}
		
		transport.send(request: request, method: HTTPMethod.post, payload:payload) { result in
			
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}

			switch result {
			case .success(let (response, _)):
				if let taggingLocation = response.valueForHTTPHeaderField(HTTPResponseHeader.location),
					let lowerBound = taggingLocation.range(of: "v2/taggings/")?.upperBound,
					let upperBound = taggingLocation.range(of: ".json")?.lowerBound,
					let taggingID = Int(taggingLocation[lowerBound..<upperBound]) {
						completion(.success(taggingID))
				} else {
					completion(.failure(TransportError.noData))
				}
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}

	func deleteTagging(taggingID: String) async throws {

		if suspended { throw TransportError.suspended }

		let callURL = feedbinBaseURL.appendingPathComponent("taggings/\(taggingID).json")
		var request = URLRequest(url: callURL, credentials: credentials)
		request.addValue("application/json; charset=utf-8", forHTTPHeaderField: HTTPRequestHeader.contentType)

		try await transport.send(request: request, method: HTTPMethod.delete)
	}

	func retrieveEntries(articleIDs: [String], completion: @escaping (Result<([FeedbinEntry]?), Error>) -> Void) {
		
		guard !articleIDs.isEmpty else {
			completion(.success(([FeedbinEntry]())))
			return
		}
		
		let concatIDs = articleIDs.reduce("") { param, articleID in return param + ",\(articleID)" }
		let paramIDs = String(concatIDs.dropFirst())
		
		let url = feedbinBaseURL
			.appendingPathComponent("entries.json")
			.appendingQueryItems([
				URLQueryItem(name: "ids", value: paramIDs),
				URLQueryItem(name: "mode", value: "extended")
			])
		let request = URLRequest(url: url!, credentials: credentials)
		
		transport.send(request: request, resultType: [FeedbinEntry].self) { result in
			
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}

			switch result {
			case .success(let (_, entries)):
				completion(.success((entries)))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}

	func retrieveEntries(feedID: String, completion: @escaping (Result<([FeedbinEntry]?, String?), Error>) -> Void) {
		
		let since = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
		let sinceString = FeedbinDate.formatter.string(from: since)
		
		let url = feedbinBaseURL
			.appendingPathComponent("feeds/\(feedID)/entries.json")
			.appendingQueryItems([
				URLQueryItem(name: "since", value: sinceString),
				URLQueryItem(name: "per_page", value: "100"),
				URLQueryItem(name: "mode", value: "extended")
			])
		let request = URLRequest(url: url!, credentials: credentials)
		
		transport.send(request: request, resultType: [FeedbinEntry].self) { result in
			
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}

			switch result {
			case .success(let (response, entries)):
				
				let pagingInfo = HTTPLinkPagingInfo(urlResponse: response)
				completion(.success((entries, pagingInfo.nextPage)))
				
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}

	func retrieveEntries(completion: @escaping (Result<([FeedbinEntry]?, String?, Date?, Int?), Error>) -> Void) {

		// If this is an initial sync, go and grab the previous 3 months of entries.  If not, use the last
		// article fetch to only get the articles **published** since the last article fetch.
		//
		// We do a backdate fetch every launch or every 24 hours.  This will help with
		// getting **updated** articles that normally wouldn't be found with a regular fetch.
		// https://github.com/Ranchero-Software/NetNewsWire/issues/2549#issuecomment-722341356
		let since: Date = {
			if let lastArticleFetch = accountMetadata?.lastArticleFetchStartTime {
				if let lastBackdateStartTime = lastBackdateStartTime {
					if lastBackdateStartTime.byAdding(days: 1) < lastArticleFetch {
						self.lastBackdateStartTime = lastArticleFetch
						return lastArticleFetch.bySubtracting(days: 1)
					} else {
						return lastArticleFetch
					}
				} else {
					self.lastBackdateStartTime = lastArticleFetch
					return lastArticleFetch.bySubtracting(days: 1)
				}
			} else {
				return Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
			}
		}()
		
		let sinceString = FeedbinDate.formatter.string(from: since)
		let url = feedbinBaseURL
			.appendingPathComponent("entries.json")
			.appendingQueryItems([
				URLQueryItem(name: "since", value: sinceString),
				URLQueryItem(name: "per_page", value: "100"),
				URLQueryItem(name: "mode", value: "extended")
			])
		let request = URLRequest(url: url!, credentials: credentials)
		
		transport.send(request: request, resultType: [FeedbinEntry].self) { result in
			
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}

			switch result {
			case .success(let (response, entries)):
				
				let dateInfo = HTTPDateInfo(urlResponse: response)

				let pagingInfo = HTTPLinkPagingInfo(urlResponse: response)
				let lastPageNumber = self.extractPageNumber(link: pagingInfo.lastPage)
				completion(.success((entries, pagingInfo.nextPage, dateInfo?.date, lastPageNumber)))
				
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
	func retrieveEntries(page: String, completion: @escaping (Result<([FeedbinEntry]?, String?), Error>) -> Void) {
		
		guard let url = URL(string: page) else {
			completion(.success((nil, nil)))
			return
		}
		
		let request = URLRequest(url: url, credentials: credentials)

		transport.send(request: request, resultType: [FeedbinEntry].self) { result in
			
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}

			switch result {
			case .success(let (response, entries)):
				
				let pagingInfo = HTTPLinkPagingInfo(urlResponse: response)
				completion(.success((entries, pagingInfo.nextPage)))

			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}

	func retrieveUnreadEntries(completion: @escaping (Result<[Int]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("unread_entries.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.unreadEntries]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)
		
		transport.send(request: request, resultType: [Int].self) { result in
			
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}

			switch result {
			case .success(let (response, unreadEntries)):
				self.storeConditionalGet(key: ConditionalGetKeys.unreadEntries, headers: response.allHeaderFields)
				completion(.success(unreadEntries))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
	func createUnreadEntries(entries: [Int], completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("unread_entries.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinUnreadEntry(unreadEntries: entries)
		transport.send(request: request, method: HTTPMethod.post, payload: payload) { result in
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}
			
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func deleteUnreadEntries(entries: [Int], completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("unread_entries.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinUnreadEntry(unreadEntries: entries)
		transport.send(request: request, method: HTTPMethod.delete, payload: payload) { result in
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}
			
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func retrieveStarredEntries(completion: @escaping (Result<[Int]?, Error>) -> Void) {
		
		let callURL = feedbinBaseURL.appendingPathComponent("starred_entries.json")
		let conditionalGet = accountMetadata?.conditionalGetInfo[ConditionalGetKeys.starredEntries]
		let request = URLRequest(url: callURL, credentials: credentials, conditionalGet: conditionalGet)
		
		transport.send(request: request, resultType: [Int].self) { result in
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}

			switch result {
			case .success(let (response, starredEntries)):
				self.storeConditionalGet(key: ConditionalGetKeys.starredEntries, headers: response.allHeaderFields)
				completion(.success(starredEntries))
			case .failure(let error):
				completion(.failure(error))
			}
			
		}
		
	}
	
	func createStarredEntries(entries: [Int], completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("starred_entries.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinStarredEntry(starredEntries: entries)
		transport.send(request: request, method: HTTPMethod.post, payload: payload) { result in
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}
			
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func deleteStarredEntries(entries: [Int], completion: @escaping (Result<Void, Error>) -> Void) {
		let callURL = feedbinBaseURL.appendingPathComponent("starred_entries.json")
		let request = URLRequest(url: callURL, credentials: credentials)
		let payload = FeedbinStarredEntry(starredEntries: entries)
		transport.send(request: request, method: HTTPMethod.delete, payload: payload) { result in
			if self.suspended {
				completion(.failure(TransportError.suspended))
				return
			}
			
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
}

// MARK: Private

private extension FeedbinAPICaller {
	
	func storeConditionalGet(key: String, headers: [AnyHashable : Any]) {
		if var conditionalGet = accountMetadata?.conditionalGetInfo {
			conditionalGet[key] = HTTPConditionalGetInfo(headers: headers)
			accountMetadata?.conditionalGetInfo = conditionalGet
		}
	}
	
	func extractPageNumber(link: String?) -> Int? {
		
		guard let link = link else {
			return nil
		}
		
		if let lowerBound = link.range(of: "page=")?.upperBound {
			let partialLink = link[lowerBound..<link.endIndex]
			if let upperBound = partialLink.firstIndex(of: "&") {
				return Int(partialLink[partialLink.startIndex..<upperBound])
			}
			if let upperBound = partialLink.firstIndex(of: ">") {
				return Int(partialLink[partialLink.startIndex..<upperBound])
			}
		}
		
		return nil
		
	}
	
}
