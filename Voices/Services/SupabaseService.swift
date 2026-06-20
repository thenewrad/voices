import Foundation
import Supabase

final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private init() {
        guard
            let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
            let config = NSDictionary(contentsOfFile: path),
            let urlString = config["SUPABASE_URL"] as? String,
            let url = URL(string: urlString),
            let anonKey = config["SUPABASE_PUBLISHABLE_KEY"] as? String
        else {
            fatalError("Config.plist is missing or malformed. Ensure SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are set.")
        }

        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}
