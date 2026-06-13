//Search.jsx

import {
  useState,
  useEffect
} from 'react';
import {
  useNavigate,
  useLocation
} from 'react-router-dom';
import { useSelector } from "react-redux";
import {
  SearchIcon,
  DeleteTextInSearchIcon
} from '../../../shared/ui';

import styles from './Search.module.css';

export function Search() {

  const navigate = useNavigate();
  const location = useLocation();

  // 1. Logic for initializing query from the address bar
  // We will use useEffect to read and set the value.
  const [query, setQuery] = useState('');

  useEffect(() => {
    // Parsing query parameters from the current URL
    const params = new URLSearchParams(location.search);
    const q = params.get('q');

    // If the 'q' parameter exists, set it to the query state
    // Use '|| '' for safety to avoid nulls
    setQuery(q || '');
  }, [location.search]); // Depend on location.search to update when the URL changes

  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);

  const handleSearch = (e) => {
    e.preventDefault();
    const trimmedQuery = query.trim();

    // If the query is empty, go to /search without the 'q' parameter
    if (trimmedQuery) {
      navigate(`/search?q=${encodeURIComponent(trimmedQuery)}`);
    } else {
      // If the line is empty, go to the base search address
      navigate('/search');
    }
  };

  // Function to clear the search bar
  const handleClearSearch = () => {
    setQuery('');
    // When clearing a field, we reset the query parameter in the URL so that SearchPage is also cleared.

    // go to the initial search page when clearing the search bar

    /* const currentPath = location.pathname; */

    // If we are on the /search page, we go to /search without parameters

    /*
    if (currentPath.startsWith('/search')) {
      navigate('/search');
    }
    */
    // /go to the initial search page when clearing the search bar

  };

  return (
    <div
      className={styles.search}
      data-search-dark-theme={darkThemeStatus}
    >
      <form role="search" onSubmit={handleSearch}>

        {query && (
          <button
            type="button"
            onClick={handleClearSearch}
            className={styles.clear_icon}
            aria-label="Clear search bar"
          >
            <DeleteTextInSearchIcon />
          </button>
        )}

        <input
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />

        <button className={styles.search_icon}
          type="submit"
          aria-label="Start search"
          disabled={!query.trim()}
        >
          <SearchIcon />
        </button>
      </form>
    </div>
  );
}